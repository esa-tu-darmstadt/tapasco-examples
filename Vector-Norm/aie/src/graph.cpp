#include "graph.h"
#include <stdio.h>


vecNormGraph my_graph;

int main(int argc, char ** argv)
{
	my_graph.init();
	my_graph.run(1);
	my_graph.end();


  return 0;
}
