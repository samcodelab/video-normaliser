import copy
import unittest
from report_benchmark import assess, LIMITS


class AssessmentTests(unittest.TestCase):
    def setUp(self):
        metrics = {k: 0.0 for k in LIMITS}
        self.case = {'id': 'global-moving', 'timingAndGeometryPreserved': True,
                     'expectedCuts': [], 'detectedCuts': [],
                     'corrected': {r: dict(metrics) for r in ('foreground', 'background')},
                     'codecFloor': {r: dict(metrics) for r in ('foreground', 'background')}}

    def test_foreground_failure_cannot_be_hidden_by_background(self):
        self.case['corrected']['foreground']['p95AbsoluteErrorEV'] = .2
        issues = assess(self.case)
        self.assertEqual(len(issues), 1)
        self.assertTrue(issues[0].startswith('foreground:'))

    def test_codec_floor_is_kept_separate(self):
        self.case['codecFloor']['foreground']['linearRGBRMSE'] = .01
        self.case['corrected']['foreground']['linearRGBRMSE'] = .034
        self.assertEqual(assess(self.case), [])
        self.case['corrected']['foreground']['linearRGBRMSE'] = .036
        self.assertEqual(len(assess(self.case)), 1)

    def test_negative_control_has_tighter_target(self):
        self.case['corrected']['background']['residualFlickerRMSEV'] = .02
        self.assertEqual(assess(self.case), [])
        for name in ['no-flicker-motion','no-flicker-zoom','no-flicker-combined-holdout']:
            self.case['id'] = name
            self.assertEqual(len(assess(self.case)), 1)

    def test_geometry_and_cut_failures_are_not_quality_passes(self):
        self.case['timingAndGeometryPreserved'] = False
        self.case['detectedCuts'] = [3]
        self.assertEqual(len(assess(self.case)), 2)

    def test_detail_damage_is_reported_even_when_ev_is_perfect(self):
        self.case['corrected']['foreground']['edgeMAE'] = .02
        self.assertEqual(len(assess(self.case)), 1)


if __name__ == '__main__':
    unittest.main()
