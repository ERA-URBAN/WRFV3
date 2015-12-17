#!/usr/bin/env python2

import subprocess
import os
from namelist import namelist_get
import argparse

def check_rsl_out(rsl_file):
  '''
  check if rsl file for SUCCESS
  '''
  # check if file exists
  if not os.path.isfile(rsl_file):
    return False  # file does not exists
  else:
    f = open(rsl_file, 'r')
  last_line = filter(None, tail(f).split(' '))
  # check if last_line contains the success keyword
  if any('success' in string.lower() for string in last_line):
#  if 'SUCCESS' in last_line:
    print last_line
    return True

def tail( f, lines=1 ):
    '''
    return last lines of a file object (default is last 1 line)
    '''
    total_lines_wanted = lines

    BLOCK_SIZE = 1024
    f.seek(0, 2)
    block_end_byte = f.tell()
    lines_to_go = total_lines_wanted
    block_number = -1
    blocks = [] # blocks of size BLOCK_SIZE, in reverse order starting
                # from the end of the file
    while lines_to_go > 0 and block_end_byte > 0:
        if (block_end_byte - BLOCK_SIZE > 0):
            # read the last block we haven't yet read
            f.seek(block_number*BLOCK_SIZE, 2)
            blocks.append(f.read(BLOCK_SIZE))
        else:
            # file too small, start from begining
            f.seek(0,0)
            # only read what was not read
            blocks.append(f.read(block_end_byte))
        lines_found = blocks[-1].count('\n')
        lines_to_go -= lines_found
        block_end_byte -= BLOCK_SIZE
        block_number -= 1
    all_read_text = ''.join(reversed(blocks))
    return '\n'.join(all_read_text.splitlines()[-total_lines_wanted:])


def main():
  pass


if __name__=="__main__":
  parser = argparse.ArgumentParser(description="Check successfull completion")
  parser.add_argument('namelist', metavar="namelist",  type=str, nargs=1, help="Namelist to parse")
  # need to add date/time ?
  args = parser.parse_args()
  # get/set namelist attribute
  #main(args)

  pyout = filter(None, subprocess.check_output(['squeue', '-u', 'haren009']).split(' '))
  try:
    pyout[8]
  except IndexError:
    print "nothing running"

  success = check_rsl_out('/home/WUR/haren009/sources/WRFV3/run/rsl.out.0000')

  import pdb; pdb.set_trace()
