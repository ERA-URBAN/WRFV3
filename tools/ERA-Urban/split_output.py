#!/usr/bin/env python

import f90nml
import copy
from config import config

class enable_split_output(config):
  '''
  description
  '''
  def __init__(self, namelist):
    config.__init__(self)
    self.namelist = namelist
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
    self.nml_copy.write('namelist.forecast.out')


  def define_dict_hourly(self):
    '''
    create dict of outputstream:variable for output that has to be saved every
    hour
    '''
    self.hourly = {
      100: 'MU',
      101: 'MUB',
      102: 'Q2',
      103: 'T2',
      104: 'TH2',
      105: 'PSFC',
      106: 'U10',
      107: 'V10',
      108: 'ANTHEAT2D',
      109: 'SEAICE',
      110: 'GRDFLX',
      111: 'ACSNOM',
      112: 'SNOW',
      113: 'SNOWH',
      114: 'CANWAT',
      115: 'SSTSK',
      116: 'TC2M_URB',
      117: 'TP2M_URB',
      118: 'UTCI_URB',
      119: 'COSZEN',
      120: 'LAI',
      121: 'VAR',
      122: 'F',
      123: 'E',
      124: 'HGT',
      125: 'TSK',
      126: 'SWDOWN',
      127: 'GLW',
      128: 'SWNORM',
      129: 'ALBEDO',
      130: 'ALBBCK',
      131: 'EMISS',
      132: 'NOAHRES',
      133: 'TMN',
      134: 'XLAND',
      135: 'UST',
      136: 'PBLH',
      137: 'HFX',
      138: 'LH',
      139: 'SNOWC',
      140: 'OLR',
      141: 'SOLDRAIN',
      142: 'SFCEXC',
      143: 'Z0',
      144: 'SST',
      145: 'RAINC',
      146: 'RAINSH',
      150: 'U',
      151: 'V',
      152: 'W',
      153: 'PH',
      154: 'PHB',
      155: 'T',
      156: 'P',
      157: 'PB',
      158: 'P_HYD',
      159: 'QVAPOR',
      160: 'QCLOUD',
      161: 'QRAIN',
      162: 'QICE',
      163: 'QSNOW',
      164: 'QGRAUP',
      165: 'CLDFRA',
      166: 'TKE',
      167: 'REFL_10CM',
      168: 'TSLB',
      169: 'SMOIS',
      170: 'SH20',
      171: 'SMCREL'
      }


  def define_dict_minute(self):
    '''
    create dict of outputstream:variable for output that has to be saved every
    minute for the inner domain
    '''
    self.minute = {
      200: 'SFROFF',
      201: 'UDROFF',
      202: 'QFX',
      203: 'SR',
      204: 'RAINNC',
      205: 'SNOWNC',
      206: 'GRAUPELNC',
      207: 'HAILNC'
      }


if __name__=="__main__":
  # TODO: add argparse menu
  enable_split_output('namelist.forecast')
