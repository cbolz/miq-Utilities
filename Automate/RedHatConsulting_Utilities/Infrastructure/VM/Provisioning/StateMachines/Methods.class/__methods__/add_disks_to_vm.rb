# Adds disks to an existing VM.
#
# PARAMETERS
#   dialog_disk_option_prefix - Prefix of disk dialog options.
#                               Default is 'disk'
#   default_bootable          - Default value for whether a disk should be bootable if no disk specific value is passed.
#                               Default is false.
#   miq_provision             - VM Provisining request contianing the VM to resize the disk of
#                               Either this or vm are required.
#   vm                        - VM to resize the disk of.
#                               Either this or miq_provision are required.
#
#   $evm.root['miq_provision'].option || $evm.root.attributes
#     #{dialog_disk_option_prefix}_#_size           - Size of the disk to add in gigabytes.
#                                                     Required.
#                                                     Maybe prefixed with 'dialog_'.
#     #{dialog_disk_option_prefix}_#_thin_provision - Thin provision, or thick provision disk.
#                                                     Optional.
#                                                     Default is true.
#                                                     Maybe prefixed with 'dialog_'.
#     #{dialog_disk_option_prefix}_#_dependent      - Whether new disk is dependent.
#                                                     Optional.
#                                                     Default is true.
#                                                     Maybe prefixed with 'dialog_'.
#     #{dialog_disk_option_prefix}_#_persistent     - Whether new disk is persistent.
#                                                     Optional.
#                                                     Default is true.
#                                                     Maybe prefixed with 'dialog_'.
#     #{dialog_disk_option_prefix}_#_bootable       - Whether new disk is bootable.
#                                                     Optional.
#                                                     Default is #{default_bootable}.
#                                                     Maybe prefixed with 'dialog_'.
#
#     EX:
#       {
#         'disk_1_size'                    => 10,
#         'disk_2_size'                    => 5,
#         'disk_2_thin_provisioned'        => false,
#         'dialog_disk_3_size'             => 20,
#         'dialog_disk_3_thin_provisioned' => true,
#         'dialog_disk_3_dependent         => false,
#         'dialog_disk_3_persistent        => false,
#         'dialog_disk_3_bootable          => false
#       }
#
@DEBUG = false

# Perform a method retry for the given reason
#
# @param seconds Number of seconds to wait before next retry
# @param reason  Reason for the retry
def automate_retry(seconds, reason)
  $evm.root['ae_result']         = 'retry'
  $evm.root['ae_retry_interval'] = "#{seconds.to_i}.seconds"
  $evm.root['ae_reason']         = reason

  $evm.log(:info, "Retrying #{@method} after #{seconds} seconds, because '#{reason}'") if @DEBUG
  exit MIQ_OK
end

# There are many ways to attempt to pass parameters in Automate.
# This function checks all of them in priorty order as well as checking for symbol or string.
#
# Order:
#   1. Inputs
#   2. Current
#   3. Object
#   4. Root
#   5. State
#
# @return Value for the given parameter or nil if none is found
def get_param(param)  
  # check if inputs has been set for given param
  param_value ||= $evm.inputs[param.to_sym]
  param_value ||= $evm.inputs[param.to_s]
  
  # else check if current has been set for given param
  param_value ||= $evm.current[param.to_sym]
  param_value ||= $evm.current[param.to_s]
 
  # else cehck if current has been set for given param
  param_value ||= $evm.object[param.to_sym]
  param_value ||= $evm.object[param.to_s]
  
  # else check if param on root has been set for given param
  param_value ||= $evm.root[param.to_sym]
  param_value ||= $evm.root[param.to_s]
  
  # check if state has been set for given param
  param_value ||= $evm.get_state_var(param.to_sym)
  param_value ||= $evm.get_state_var(param.to_s)

  $evm.log(:info, "{ '#{param}' => '#{param_value}' }") if @DEBUG
  return param_value
end

begin
  # get parameters
  $evm.log(:info, "$evm.root['vmdb_object_type'] => '#{$evm.root['vmdb_object_type']}'.") if @DEBUG
  case $evm.root['vmdb_object_type']
    when 'miq_provision'
      miq_provision = $evm.root['miq_provision']
      vm            = miq_provision.vm
      options       = miq_provision.options
    when 'vm'
      vm      = get_param(:vm)
      options = $evm.root.attributes
    else
      error("Can not handle vmdb_object_type: #{$evm.root['vmdb_object_type']}")
  end
  error("vm not found")      if vm.blank?
  error("options not found") if options.blank?
  
  disk_option_prefix = get_param(:dialog_disk_option_prefix)
  default_bootable   = get_param(:default_bootable)
 
  # determine the datastore name
  if !vm.storage.nil?
    datastore_name = vm.storage.name
  elsif !miq_provision.nil?
    datastore_name = miq_provision.options[:dest_storage][1]
  end
  error("Could not determine destination datastore name") if datastore_name.nil?
  
  # collect new disk info
  new_disks = {}
  options.select { |option, value| option.to_s =~ /^(dialog_)?#{disk_option_prefix}_([0-9]+)_/ }.each do |disk_option, disk_value|
    # determine new disk attribute
    captures  = disk_option.to_s.match(/#{disk_option_prefix}_([0-9]+)_(.*)/)
    disk_num  = captures[1]
    disk_attr = captures[2]
    
    # ensure these attributes are converted to booleans
    if (disk_attr == 'thin_provisioned' ||
       disk_attr == 'dependent' ||
       disk_attr == 'persistent' ||
       disk_attr == 'bootable')
      
      # if value is a string, convert to a boolean
      if disk_value.kind_of? String
        $evm.log(:info, "Convert disk attribute '#{disk_attr}' value to boolean: #{disk_value}") if @DEBUG
        disk_value = (disk_value =~ /t|true|y|yes/im) == 0
      end
    end
    
    # set new disk attribute
    new_disks[disk_num]          ||= {}
    new_disks[disk_num][disk_attr] = disk_value
  end
  
  # create disks
  $evm.log(:info, "new_disks => #{new_disks}") if @DEBUG
  new_disks.each do |disk_num, disk_options|
    $evm.log(:info, "{ disk_num => #{disk_num}, disk_options => #{disk_options}, datastore => #{datastore_name} }") if @DEBUG
    
    size             = disk_options['size']             || 0
    thin_provisioned = disk_options['thin_provisioned'] || true
    dependent        = disk_options['dependent']        || true
    persistent       = disk_options['persistent']       || true
    bootable         = disk_options['bootable']         || default_bootable
    
    # don't add disks with a size of 0
    if disk_options['size'].nil? || disk_options['size'] == 0
      $evm.log(:info, "Skip disk '#{disk_num}' with size of 0")
      next
    end
    
    # add the aditional disk
    $evm.log(:info, "Add new disk of size '#{size}'G to VM '#{vm.name}'") if @DEBUG
    size_mb = size.to_i * 1024 # assume size is in gigabytes
    vm.add_disk(
      nil, # API want's this to be nil, why it asks for it is unknown....
      size_mb,
      {
        :datastore        => datastore_name,
        :thin_provisioned => thin_provisioned,
        :dependent        => dependent,
        :persistent       => persistent,
        :bootable         => bootable
      }
    )
  end
end
