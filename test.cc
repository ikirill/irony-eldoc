#include <vector>
#include <string>
using namespace std;

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
  f(x);
  f(x, x);
  g(x);
}

// Local Variables:
// eval: (when (fboundp (quote flycheck-mode)) (flycheck-mode -1))
// End:
