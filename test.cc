#include <vector>
#include <string>
#include <algorithm>
#include <boost/geometry.hpp>
#include <boost/geometry/geometries/point_xy.hpp>
#include <boost/geometry/geometries/polygon.hpp>
using namespace boost::geometry;
// using namespace std;

/** docstring for f */
void f(string x);
/** docstring for f */
void f(int x, int y);
/** docstring for f */
void f(double x, double y);
/** docstring for g */
void g(string /** arg */ x) {
  /** vector y */
  vector<float> y;
  y = vector<float>(10, 0.1);
  sort(y.begin(), y.end());
  f(x);
  f(x, x);
  g(x);
  model::d2::point_xy<int> p1(1, 1), p2(2, 2);
  std::cout << "Distance p1-p2 is: " << distance(p1, p2) << std::endl;
}

// Local Variables:
// eval: (when (fboundp (quote flycheck-mode)) (flycheck-mode -1))
// End:
