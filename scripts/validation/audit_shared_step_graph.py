"""Offline bounded shared residual solve with spatially held-out evaluation."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def solve(count, edges, weight):
    diagonal, lower, rhs = [1.0]*count, [0.0]*count, [0.0]*count
    for edge in edges:
        index, residual = edge[:2]
        edge_weight = edge[2] if len(edge) > 2 else weight
        diagonal[index-1] += edge_weight
        diagonal[index] += edge_weight
        lower[index] -= edge_weight
        rhs[index-1] += edge_weight*residual
        rhs[index] -= edge_weight*residual
    for i in range(1, count):
        factor = lower[i]/diagonal[i-1]
        diagonal[i] -= factor*lower[i]
        rhs[i] -= factor*rhs[i-1]
    result = rhs[:]
    for i in range(count-1, -1, -1):
        result[i] = (rhs[i]-(lower[i+1]*result[i+1] if i+1 < count else 0))/diagonal[i]
    centre = statistics.median(result)
    return [max(-.25, min(.25, value-centre)) for value in result]


def main():
    p = argparse.ArgumentParser()
    p.add_argument('matched', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--width', type=int, default=96)
    p.add_argument('--fps', type=float, required=True)
    p.add_argument('--radius', type=float, default=.5)
    p.add_argument('--protect-neighbors', action='store_true')
    p.add_argument('--source-coherence', action='store_true')
    a = p.parse_args()
    assert not a.output.exists()
    data = json.loads(a.matched.read_text())
    transitions = data['transitions']
    # Missing adjacent transitions identify cuts in the authoritative report.
    end = max(t['frames'][1] for t in transitions)+1
    cuts = [0]+[i for i in range(1, end) if not any(t['frames']==[i-1, i] for t in transitions)]+[end]
    rows = []
    for side in (False, True):
        adjustments = [0.0]*end
        accepted = []
        for start, stop in zip(cuts, cuts[1:]):
            measures = []
            for t in transitions:
                index = t['frames'][1]
                if not start < index < stop:
                    continue
                source_eligible = True
                if a.source_coherence:
                    all_source = [q['sourceLumaStepEV'] for q in t['sourceSelectedMatchedFootprints']]
                    counts = [sum((q['x'] >= a.width/2) == s for q in t['sourceSelectedMatchedFootprints']) for s in (False, True)]
                    source_eligible = bool(all_source) and min(counts) >= 6
                    if source_eligible:
                        common = statistics.median(all_source)
                        source_eligible = abs(common) >= .08 and sum(v*common > 0 for v in all_source)/len(all_source) >= .9
                train = [q for q in t['sourceSelectedMatchedFootprints'] if (q['x'] >= a.width/2) == side]
                if len(train) < 6:
                    continue
                source = statistics.median(q['sourceLumaStepEV'] for q in train)
                agreement = sum(q['sourceLumaStepEV']*source > 0 for q in train)/len(train)
                # Small steps keep the established stable-source behaviour;
                # large steps require distributed same-direction evidence.
                if abs(source) > .05 and agreement < .9:
                    continue
                rendered = statistics.median(q['outputLumaStepEV'] for q in train)
                measures.append((index, source, rendered, train, source_eligible))
            edges = {index: (index, 0, 16) for index in range(1, stop-start)} if a.protect_neighbors else {}
            for index, source, rendered, train, source_eligible in measures:
                nearby = [step for j, step, _, _, _ in measures if abs(j-index) <= a.radius*a.fps]
                if len(nearby) < 3:
                    continue
                trend = statistics.median(nearby)
                if not source_eligible:
                    continue
                residual = rendered-trend
                if a.protect_neighbors:
                    agreement = sum((q['outputLumaStepEV']-trend)*residual > 0 for q in train)/len(train)
                    if abs(residual) < .06 or agreement < .9:
                        continue
                edges[index-start] = (index-start, residual, 4)
                accepted.append(index)
            if edges:
                adjustments[start:stop] = solve(stop-start, list(edges.values()), 4)
        for t in transitions:
            first, second = t['frames']
            held = [q for q in t['sourceSelectedMatchedFootprints'] if (q['x'] >= a.width/2) != side]
            if len(held) < 6:
                continue
            before = [q['outputLumaStepEV'] for q in held]
            delta = adjustments[second]-adjustments[first]
            after = [v+delta for v in before]
            rows.append({'frames': [first, second], 'trainingRight': side,
                         'acceptedTrainingEdge': second in accepted,
                         'heldOutFootprints': len(held), 'adjustmentStepEV': delta,
                         'beforeMedianAbsoluteLumaEV': statistics.median(map(abs, before)),
                         'afterMedianAbsoluteLumaEV': statistics.median(map(abs, after))})
    report = {'status': 'Offline diagnostic, not production or an export.', 'protectNeighbors': a.protect_neighbors,
              'sourceCoherenceGate': a.source_coherence, 'rows': rows,
              'method': 'Scene-isolated regularized adjacent residual solve, median derivative trend, '
              '0.25 EV bound; one spatial half trains and the other is evaluated, reversed.',
              'limitations': 'Same-direction material changes can resemble shared lighting. '
              'Clipping and nonlinear highlight protection are not rendered here. '
              'Sparse measurements and median derivative trends can miss intentional transitions.',
              'sha256': {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in (a.matched, Path(__file__))}}
    a.output.write_text(json.dumps(report, indent=2)+'\n')
    selected = [r for r in rows if r['frames'][1] in range(183, 193)]
    print(json.dumps(selected, indent=2))


if __name__ == '__main__':
    main()
