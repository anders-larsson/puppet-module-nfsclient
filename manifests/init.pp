# nfsclient
class nfsclient (
  $gss    = false,
  $keytab = undef,
) {

  if is_bool($gss) == true {
    $gss_bool = $gss
  } else {
    $gss_bool = str2bool($gss)
  }

  if $keytab != undef {
    validate_absolute_path($keytab)
  }

  case $::osfamily {
    'RedHat': {
      $gss_line     = 'SECURE_NFS'
      $keytab_line  = 'RPCGSSDARGS'
      $nfs_sysconf  = '/etc/sysconfig/nfs'
      $nfs_requires = Service['idmapd_service']
      $service      = 'rpcgssd'

      include ::nfs::idmap
    }
    'Suse': {
      $gss_line    = 'NFS_SECURITY_GSS'
      $keytab_line = 'GSSD_OPTIONS'
      $nfs_sysconf  = '/etc/sysconfig/nfs'
      $nfs_requires = undef
      $service = $::operatingsystemrelease ? {
        /^11/   => 'nfs',
        default => 'rpc-gssd',
      }
    }
    'Debian': {
      if $::operatingsystem != 'Ubuntu' {
        fail('nfsclient module only supports Suse, RedHat and Ubuntu. Debian was detected.')
      }
      $gss_line     = 'NEED_GSSD'
      $keytab_line  = 'GSSDARGS'
      $nfs_sysconf  = '/etc/default/nfs-common'
      $nfs_requires = undef
      $service      = 'rpc-gssd'

      # Puppet 3.x Incorrectly defaults to upstart for Ubuntu >= 16.x
      Service {
        provider => 'systemd',
      }
    }
    default: {
      fail("nfsclient module only supports Suse, RedHat and Ubuntu. <${::osfamily}> was detected.")
    }
  }

  if $gss_bool {
    $_gssd_options_notify = [ Service[rpcbind_service], Service[$service] ]
    $_krb5_keytab_notify = Service[$service]

    include ::rpcbind

    file_line { 'NFS_SECURITY_GSS':
      path   => $nfs_sysconf,
      line   => "${gss_line}=\"yes\"",
      match  => "^${gss_line}=.*",
      notify => Service[rpcbind_service],
    }

    service { $service:
      ensure    => 'running',
      enable    => true,
      subscribe => File_line['NFS_SECURITY_GSS'],
      require   =>  $nfs_requires,
    }

    if "${::osfamily}-${::operatingsystemrelease}" =~ /^Suse-11/ {
      file_line { 'NFS_START_SERVICES':
        match  => '^NFS_START_SERVICES=',
        path   => '/etc/sysconfig/nfs',
        line   => 'NFS_START_SERVICES="yes"',
        notify => [ Service[nfs], Service[rpcbind_service], ],
      }
      file_line { 'MODULES_LOADED_ON_BOOT':
        match  => '^MODULES_LOADED_ON_BOOT=',
        path   => '/etc/sysconfig/kernel',
        line   => 'MODULES_LOADED_ON_BOOT="rpcsec_gss_krb5"',
        notify => Exec[gss-module-modprobe],
      }
      exec { 'gss-module-modprobe':
        command     => 'modprobe rpcsec_gss_krb5',
        unless      => 'lsmod | egrep "^rpcsec_gss_krb5"',
        path        => '/sbin:/usr/bin',
        refreshonly => true,
      }
    }
  }
  else {
    $_gssd_options_notify = undef
    $_krb5_keytab_notify = undef
  }

  if $keytab {
    file_line { 'GSSD_OPTIONS':
      path   => $nfs_sysconf,
      line   => "${keytab_line}=\"-k ${keytab}\"",
      match  => "^${keytab_line}=.*",
      notify => $_gssd_options_notify,
    }

    if "${::osfamily}-${::operatingsystemrelease}" =~ /^(Debian-16.04|Debian-18.04|Suse-12|RedHat-7)/ {
      file { '/etc/krb5.keytab':
        ensure => 'symlink',
        target => $keytab,
        notify => $_krb5_keytab_notify,
      }
    }

    if "${::osfamily}-${::operatingsystemrelease}" =~ /^RedHat-7/ {
      exec { 'nfs-config':
        command     => 'service nfs-config start',
        path        => '/sbin:/usr/sbin',
        refreshonly => true,
        subscribe   => File_line['GSSD_OPTIONS'],
      }
      if $gss_bool {
        Exec['nfs-config'] ~> Service[$service]
        Service['rpcbind_service'] -> Service[$service]
      }
    }
  }
}
