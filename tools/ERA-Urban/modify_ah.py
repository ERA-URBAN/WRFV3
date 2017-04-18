#!/usr/bin/env python

import argparse
import datetime
import dateutil.parser
import os
import shutil

class modify_ah:
  def __init__(self, filename, date_in):
    self.filename = filename
    # parse date and get month number
    try:
        date = datetime.datetime.strptime(date_in, '%Y%m%dT%H00+01').replace(tzinfo=None)
    except ValueError:
        date = dateutil.parser.parse(date_in).replace(tzinfo=None)
    month = date.month
    # get anthropogenic heating values for each month
    ah = self.define_list_ah(month)
    # modify URBPARAM.TBL
    self.modify_urbparam(ah[month])

  def define_list_ah(self, month):
    '''
    define monthly values for anthropogenic heating
    '''
    ah = {}
    ah[1] = [46.8, 46.8, 46.8, 46.8]
    ah[2] = [42.5, 42.5, 42.5, 42.5]
    ah[3] = [41.5, 41.5, 41.5, 41.5]
    ah[4] = [34.5, 34.5, 34.5, 34.5]
    ah[5] = [27.5, 27.5, 27.5, 27.5]
    ah[6] = [21.6, 21.6, 21.6, 21.6]
    ah[7] = [22.2, 22.2, 22.2, 22.2]
    ah[8] = [22.0, 22.0, 22.0, 22.0]
    ah[9] = [25.7, 25.7, 25.7, 25.7]
    ah[10] = [25.7, 25.7, 25.7, 25.7]
    ah[11] = [36.0, 36.0, 36.0, 36.0]
    ah[12] = [46.2, 46.2, 46.2, 46.2]
    return ah

  def modify_urbparam(self, ah):
    '''
    modify URBPARAM.TBL anthropogenic heating values
    backup existing file
    '''
    textToReplace = 'AH: ' + ','.join(str(e) for e in ah)
    filename_bak = self.filename + '.bak'
    # delete backup file if exists
    try:
      os.remove(filename_bak)
    except OSError:
      pass
    # create backup
    shutil.copyfile(self.filename, filename_bak)
    f_bak = open(filename_bak, 'r')
    f = open(self.filename, 'w')
    for line in f_bak:
      if (("AH:" in line) and not (line.lstrip().startswith('#'))):
        # You need to include a newline if you're replacing the whole line
        line = textToReplace + '\n' 
      f.write(line)
    f.close()
    f_bak.close()

if __name__=="__main__":
  # define argument menu
  description = 'Change antropogenic heat URBPARAM.TBL'
  parser = argparse.ArgumentParser(description=description)
  # fill argument groups
  parser.add_argument('-f', '--filename', help='URBPARAM.TBL file',
		      default='URBPARAM.TBL', required=False)
 
  parser.add_argument('-d', '--date', help='datestring', required=True)
  opts = parser.parse_args()
  modify_ah(opts.filename, opts.date)
