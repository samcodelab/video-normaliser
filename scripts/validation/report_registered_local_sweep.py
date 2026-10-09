"""Pair registered local refinement with retained build33 mathematics at identical settings."""
import argparse
import hashlib
import json
from pathlib import Path
from run_slider_matrix import PROFILES, STEADY
ROOT = Path(__file__).resolve().parents[2]
REVISION = 'v33-registered-local-v3'

def collect(require_complete=True):
    frozen = ROOT/'.build/review-v33/registered-local-experiment/runner-v3'
    expected = json.loads((frozen/'build-provenance.json').read_text())
    assert hashlib.sha256((frozen/'audit').read_bytes()).hexdigest() == expected['binarySha256']
    records, pending = [], []
    for suite in ['development','holdout','adversarial']:
        dataset = ROOT/'dist/Benchmarks'/('adversarial-v30' if suite == 'adversarial' else f'motion-v2-{suite}')
        case_ids = {x['id'] for x in json.loads((dataset/'manifest.json').read_text())['cases']}
        for mode in ['smooth','steady']:
            for name, parameters in PROFILES.items():
                if mode == 'steady' and name not in STEADY:
                    continue
                label = f'slider-range-{REVISION}-{mode}-{name}'
                folder = dataset/'results'/label
                if not (folder/'sweep-profile.json').exists():
                    pending.append(f'{suite}/{mode}/{name}')
                    continue
                profile = json.loads((folder/'sweep-profile.json').read_text())
                assert profile['parameters'] == parameters and profile['name'] == name and profile['mode'] == mode
                provenance = json.loads((folder/'provenance.json').read_text())
                assert provenance['binarySha256'] == expected['binarySha256']
                assert provenance['pipelineSha256'] == expected['pipelineSha256']
                prefix = 'v32-registered-anchor-v2'
                before = json.loads((dataset/'results'/f'slider-range-{prefix}-{mode}-{name}'/'scores.json').read_text())
                baseline = {x['id']:x for x in before}
                after = json.loads((folder/'scores.json').read_text())
                assert {x['id'] for x in after} == set(baseline) == case_ids
                (folder/'experimental-options.json').write_text(json.dumps({'FRANKLUMA_REGISTERED_LOCAL':'1','FRANKLUMA_REGISTERED_ANCHOR':'default-enabled','FRANKLUMA_CONTRAST_TRACKING':'default-enabled','FRANKLUMA_SMOOTH_PATCH_VALIDATION':'default-enabled','otherOptInExperimentalFlags':'off','immutableRunnerBinarySha256':expected['binarySha256']},indent=2)+'\n')
                for item in after:
                    assert item['timingAndGeometryPreserved'] and item['detectedCuts'] == item['expectedCuts']
                    control = json.loads((folder/item['id']/'control-evidence.json').read_text())
                    if parameters.get('strength') == 0:
                        assert all(control[x] == 0 for x in ['brightnessPeakEV','globalPeakEV','localPeakEV'])
                    if parameters.get('spatial-strength') == 0:
                        assert control['localPeakEV'] == 0
                    regions = {}
                    for region in ['foreground','background']:
                        old = baseline[item['id']]['corrected'][region]
                        new = item['corrected'][region]
                        regions[region] = {'before':old,'after':new,'rmsChangeEV':new['residualFlickerRMSEV']-old['residualFlickerRMSEV'],'p95ChangeEV':new['p95AbsoluteErrorEV']-old['p95AbsoluteErrorEV']}
                    records.append({'suite':suite,'case':item['id'],'mode':mode,'profile':name,'parameters':parameters,'regions':regions,'timingAndCutsPassed':True})
    if require_complete:
        assert not pending, f'{len(pending)} profiles remain'
        assert len(records) == 450
    return {'completedEncodedCases':len(records),'expectedEncodedCases':450,'pendingProfiles':pending,'runnerProvenance':expected,'comparisons':records}

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--progress',action='store_true')
    args=parser.parse_args()
    result=collect(not args.progress)
    print(json.dumps({'completedEncodedCases':result['completedEncodedCases'],'pendingProfiles':len(result['pendingProfiles']),'largestForegroundRMSIncreaseEV':max((x['regions']['foreground']['rmsChangeEV'] for x in result['comparisons']),default=None)},indent=2))
    output=ROOT/'dist/Benchmarks/general-review-v30/registered-local-slider-sweep.json'
    result['complete']=not result['pendingProfiles'] and result['completedEncodedCases']==450
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(output)
