cmake_minimum_required(VERSION 3.25 FATAL_ERROR)
set(CMAKE_CXX_STANDARD 23)

project(nvme-rw-sw-prj)

find_package(Threads)
find_package(Boost COMPONENTS program_options REQUIRED)
find_package(Tapasco REQUIRED)

include_directories(../../nvme-host-driver)
add_executable(nvme-rw-sw main.cpp)
target_link_libraries(nvme-rw-sw tapasco ${CMAKE_THREAD_LIBS_INIT} Boost::program_options)
