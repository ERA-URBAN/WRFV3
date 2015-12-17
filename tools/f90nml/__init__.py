"""f90nml
   ======

   A Fortran 90 namelist parser and generator.

   :copyright: Copyright 2014 Marshall Ward, see AUTHORS for details.
   :license: Apache License, Version 2.0, see LICENSE for details.
"""
__version__ = '0.10.2'

from f90nml.parser import Parser

# Legacy API functions

def read(nml_fname):
    """Parse a Fortran 90 namelist file (data.nml) and store its contents.

    >>> nml = f90nml.read('data.nml')"""
    return Parser().read(nml_fname)

def write(nml, nml_fname, force=False):
    """Output namelist (nml) to a Fortran 90 namelist file (data.nml).

    >>> f90nml.write(nml, 'data.nml')"""
    nml.write(nml_fname, force)

def patch(nml_fname, nml_patch, out_fname=None):
    """Create a new namelist based on an input namelist and reference dict.

    >>> f90nml.patch('data.nml', nml_patch, 'patched_data.nml')"""
    return Parser().read(nml_fname, nml_patch, out_fname)
