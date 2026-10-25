#import <Foundation/Foundation.h>
// Apple parametric curves store coefficients in signed 16.16 fixed point.
NSArray *TSScaleCurves(NSArray *curves, double scale, NSError **error);
double TSEvaluateCurve(NSDictionary *curve, double speed);
// Snapshot expectations mirror Apple interpolation and exported 16.16 debug coefficients.
NSDictionary *TSExpectedActiveCurve(NSArray *curves, double fixedIndex);
BOOL TSActiveCurveMatches(NSArray *curves, double fixedIndex, NSDictionary *active, NSDictionary **diff);
// strength=1 preserves the original shape; contrast pivots around a normalized reference.
NSArray *TSAdjustCurves(NSArray *curves, double scale, double strength, NSError **error);

NSArray *TSAnchoredCurves(NSArray *curves, double scale, double strength, double fixedIndex, NSDictionary **info, NSError **error);

double TSMinimumContrast(void);
double TSMaximumContrast(void);
