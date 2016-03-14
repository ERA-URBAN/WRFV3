#!/usr/bin/env python

import f90nml
import copy
import argparse

class enable_split_output:
  '''
  add split output streams to a WRF namelist.input file
  '''
  def __init__(self, namelist, output=None):
    self.namelist = namelist
    if output==None:
      # save output as input filename with .out added
      self.output = namelist + '.out'
    else:
      # use output file as provided by user
      self.output = output
    self.read_namelist()
    self.create_namelist_copies()
    self.add_hourly_variables()
    self.add_minute_variables()
    self.save_output()


  def read_namelist(self):
    '''
    read user supplied namelist
    '''
    self.nml = f90nml.read(self.namelist)
    # get list of namelist keys
    self.keys = self.nml.keys()


  def create_namelist_copies(self):
    '''
    create two (shallow) copies of the variable containing the namelist
    which will be used to create the output namelists
    '''
    self.nml_copy = copy.copy(self.nml)


  def add_hourly_variables(self):
    '''
    add variables defined by define_dict_hourly(self) to namelist
    '''
    self.define_dict_hourly()
    max_dom = int(self.nml_copy['domains']['max_dom'])
    for key in self.hourly.keys():
      self.nml_copy['time_control']['io_form_auxhist' + str(key)] = 2
      self.nml_copy['time_control']['auxhist' + str(key) + '_interval'
                                    ] = max_dom * [60]
      self.nml_copy['time_control']['frames_per_auxhist' + str(key)] = 1000
      self.nml_copy['time_control']['auxhist' + str(key) + '_outname'
                                    ] = self.hourly[key] + '_d<domain>_<date>'


  def add_minute_variables(self):
    '''
    add variables defined by define_dict_hourly(self) to namelist
    '''
    self.define_dict_minute()
    max_dom = int(self.nml_copy['domains']['max_dom'])
    for key in self.hourly.keys():
      self.nml_copy['time_control']['io_form_auxhist' + str(key)] = 2
      self.nml_copy['time_control']['auxhist' + str(key) + '_interval'
                                    ] = (max_dom - 1) * [60] + [1]
      self.nml_copy['time_control']['frames_per_auxhist' + str(key)] = 1000
      self.nml_copy['time_control']['auxhist' + str(key) + '_outname'
                                    ] = self.hourly[key] + '_d<domain>_<date>'


  def save_output(self):
    ''' 
    write output namelist to file
    '''
    self.nml_copy.write(self.output)


  def define_dict_hourly(self):
    '''
    create dict of outputstream:variable for output that has to be saved every
    hour
    '''
    self.hourly = {
      41: 'P_TOP',
      42: 'T00',
      43: 'P00',
      44: 'ZETATOP',
      45: 'ZNU',
      46: 'ZNW',
      47: 'ZS',
      48: 'DZS',
      49: 'VEGFRA',
      50: 'MU',
      51: 'MUB',
      52: 'Q2',
      53: 'T2',
      54: 'TH2',
      55: 'PSFC',
      56: 'U10',
      57: 'V10',
      58: 'ANTHEAT2D',
      59: 'SEAICE',
      60: 'GRDFLX',
      61: 'ACSNOM',
      62: 'SNOW',
      63: 'SNOWH',
      64: 'CANWAT',
      65: 'SSTSK',
      66: 'TC2M_URB',
      67: 'TP2M_URB',
      68: 'UTCI_URB',
      69: 'COSZEN',
      70: 'LAI',
      71: 'VAR',
      72: 'F',
      73: 'E',
      74: 'HGT',
      75: 'TSK',
      76: 'SWDOWN',
      77: 'GLW',
      78: 'SWNORM',
      79: 'ALBEDO',
      80: 'ALBBCK',
      81: 'EMISS',
      82: 'NOAHRES',
      83: 'TMN',
      84: 'XLAND',
      85: 'UST',
      86: 'PBLH',
      87: 'HFX',
      88: 'LH',
      89: 'SNOWC',
      90: 'OLR',
      91: 'SOLDRAIN',
      92: 'SFCEXC',
      93: 'Z0',
      94: 'SST',
      95: 'RAINC',
      96: 'RAINSH',
      100: 'U',
      101: 'V',
      102: 'W',
      103: 'PH',
      104: 'PHB',
      105: 'T',
      106: 'P',
      107: 'PB',
      108: 'P_HYD',
      109: 'QVAPOR',
      110: 'QCLOUD',
      111: 'QRAIN',
      112: 'QICE',
      113: 'QSNOW',
      114: 'QGRAUP',
      115: 'CLDFRA',
      116: 'TKE',
      117: 'REFL_10CM',
      118: 'TSLB',
      119: 'SMOIS',
      120: 'SH20',
      121: 'SMCREL'
      }


  def define_dict_minute(self):
    '''
    create dict of outputstream:variable for output that has to be saved every
    minute for the inner domain
    '''
    self.minute = {
      125: 'SFROFF',
      126: 'UDROFF',
      127: 'QFX',
      128: 'SR',
      129: 'RAINNC',
      130: 'SNOWNC',
      131: 'GRAUPELNC',
      132: 'HAILNC'
      }


def main():
  '''
  define argparse menu and call enable_split_output() class
  '''
  parser = argparse.ArgumentParser(
    description='add split output streams to a WRF namelist.input file')
  parser.add_argument('input', metavar='INPUT', type=str, nargs=1,
                      help='input namelist.input')
  parser.add_argument('-o', '--output', type=str,
                      help='ouput namelist.input')
  # array of all arguments passed to script
  args = parser.parse_args()
  # add split output streams to a WRF namelist.input file
  enable_split_output(args.input[0], args.output)


if __name__=="__main__":
  main()
