import 'dart:math';

/// A pure Dart implementation of Homography (Perspective Transform)
/// to avoid heavy native dependencies for simple 4-point mapping.
class HomographyLogic {
  
  /// Calculates the 3x3 homography matrix that maps [srcPts] to [dstPts].
  /// 
  /// [srcPts] and [dstPts] must both contain exactly 4 points in the order:
  /// [TopLeft, TopRight, BottomRight, BottomLeft].
  /// 
  /// Returns a list of 9 doubles representing the flattened 3x3 matrix.
  static List<double> findHomography(List<Point<double>> src, List<Point<double>> dst) {
    if (src.length != 4 || dst.length != 4) {
      throw ArgumentError('Source and Destination must have exactly 4 points.');
    }

    // We need to solve the system Ah = 0 (or similar) to find the 8 coefficients (h33 = 1).
    // Gaussian elimination implementation.
    
    // Based on standard planar homography algorithms.
    // h = [h0, h1, h2, h3, h4, h5, h6, h7, 1]
    // x' = (h0*x + h1*y + h2) / (h6*x + h7*y + 1)
    // y' = (h3*x + h4*y + h5) / (h6*x + h7*y + 1)

    // Build the matrix P (8x8) and vector b (8x1) to solve Ph = b
    // But typically we solve for 8 unknowns.
    
    final pMat = List.generate(8, (_) => List.filled(8, 0.0));
    final bVec = List.filled(8, 0.0);

    for (var i = 0; i < 4; i++) {
      final s = src[i]; // x, y
      final d = dst[i]; // u, v

      // Row 2*i
      pMat[2 * i][0] = s.x;
      pMat[2 * i][1] = s.y;
      pMat[2 * i][2] = 1;
      pMat[2 * i][3] = 0;
      pMat[2 * i][4] = 0;
      pMat[2 * i][5] = 0;
      pMat[2 * i][6] = -s.x * d.x;
      pMat[2 * i][7] = -s.y * d.x;
      bVec[2 * i] = d.x;

      // Row 2*i + 1
      pMat[2 * i + 1][0] = 0;
      pMat[2 * i + 1][1] = 0;
      pMat[2 * i + 1][2] = 0;
      pMat[2 * i + 1][3] = s.x;
      pMat[2 * i + 1][4] = s.y;
      pMat[2 * i + 1][5] = 1;
      pMat[2 * i + 1][6] = -s.x * d.y;
      pMat[2 * i + 1][7] = -s.y * d.y;
      bVec[2 * i + 1] = d.y;
    }

    final h = _solveGaussian(pMat, bVec);
    return [...h, 1.0];
  }

  /// Projects a point [p] using the homography matrix [h].
  static Point<double> project(Point<double> p, List<double> h) {
    final x = p.x;
    final y = p.y;
    
    final xx = h[0] * x + h[1] * y + h[2];
    final yy = h[3] * x + h[4] * y + h[5];
    final ww = h[6] * x + h[7] * y + h[8];

    return Point(xx / ww, yy / ww);
  }

  /// Solves Ax = b using Gaussian elimination.
  static List<double> _solveGaussian(List<List<double>> A, List<double> b) {
    final n = b.length;
    // Augment A with b
    for (var i = 0; i < n; i++) {
      A[i].add(b[i]);
    }

    for (var i = 0; i < n; i++) {
      // Find pivot
      var maxEl = (A[i][i]).abs();
      var maxRow = i;
      for (var k = i + 1; k < n; k++) {
        if ((A[k][i]).abs() > maxEl) {
          maxEl = (A[k][i]).abs();
          maxRow = k;
        }
      }

      // Swap rows
      final tmp = A[maxRow];
      A[maxRow] = A[i];
      A[i] = tmp;

      // Make all rows below this one 0 in current column
      for (var k = i + 1; k < n; k++) {
        final c = -A[k][i] / A[i][i];
        for (var j = i; j < n + 1; j++) {
          if (i == j) {
            A[k][j] = 0;
          } else {
            A[k][j] += c * A[i][j];
          }
        }
      }
    }

    // Back substitution
    final x = List.filled(n, 0.0);
    for (var i = n - 1; i >= 0; i--) {
      var sum = 0.0;
      for (var j = i + 1; j < n; j++) {
        sum += A[i][j] * x[j];
      }
      x[i] = (A[i][n] - sum) / A[i][i];
    }
    return x;
  }
}
