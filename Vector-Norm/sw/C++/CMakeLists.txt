cmake_minimum_required(VERSION 3.5.1 FATAL_ERROR)
set(CMAKE_CXX_STANDARD 23)

project(vector-norm-prj)

find_package(Threads)
find_package(Boost COMPONENTS program_options REQUIRED)
find_package(Tapasco REQUIRED)

add_executable(vector-norm main.cpp)
target_link_libraries(vector-norm tapasco ${CMAKE_THREAD_LIBS_INIT} Boost::program_options)


