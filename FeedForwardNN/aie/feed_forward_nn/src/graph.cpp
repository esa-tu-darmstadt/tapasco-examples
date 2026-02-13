
#include "graph.h"

TopGraph g;

#ifdef __AIESIM__

   int main(void)
   {
      g.init();
      g.run(4);
      g.end();
   
      return 0;
   }

#endif


#ifdef __X86SIM__

   int main(void)
   {
      g.init();
      g.run(2);
      g.end();
   
      return 0;
   }

#endif
