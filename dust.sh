#!/bin/bash

# I/O fnames
ifiles="faerie.f90"
ofile="faerie"

# Compiler and flags
fcom=gfortran
fflags="-g -fcheck=all -fbacktrace -Wall -Wextra -O0 -pedantic"
nfflags=`nf-config --fflags`
nfflibs=`nf-config --flibs`

# Compile command
$fcom $fflags $nfflags $ifiles $nfflibs -o $ofile

# Optionally run
if [[ $1 == 'run' ]]
then
  ./$ofile
fi