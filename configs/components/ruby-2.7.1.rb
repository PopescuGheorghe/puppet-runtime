component 'ruby-2.7.1' do |pkg, settings, platform|
  pkg.version '2.7.1'
  pkg.sha256sum 'd418483bdd0000576c1370571121a6eb24582116db0b7bb2005e90e250eae418'

  # rbconfig-update is used to munge rbconfigs after the fact.
  pkg.add_source("file://resources/files/ruby/rbconfig-update.rb")

  # PDK packages multiple rubies and we need to tweak some settings
  # if this is not the *primary* ruby.
  if pkg.get_version != settings[:ruby_version]
    # not primary ruby

    # ensure we have config for this ruby
    unless settings.key?(:additional_rubies) && settings[:additional_rubies].key?(pkg.get_version)
      raise "missing config for additional ruby #{pkg.get_version}"
    end

    ruby_settings = settings[:additional_rubies][pkg.get_version]

    ruby_dir = ruby_settings[:ruby_dir]
    ruby_bindir = ruby_settings[:ruby_bindir]
    host_ruby = ruby_settings[:host_ruby]
  else
    # primary ruby
    ruby_dir = settings[:ruby_dir]
    ruby_bindir = settings[:ruby_bindir]
    host_ruby = settings[:host_ruby]
  end

  # Most ruby configuration happens in the base ruby config:
  instance_eval File.read('configs/components/_base-ruby.rb')
  # Configuration below should only be applicable to ruby 2.5

  #########
  # PATCHES
  #########

  base = 'resources/patches/ruby_27'
  # Patch for https://bugs.ruby-lang.org/issues/14972
  pkg.apply_patch "#{base}/net_http_eof_14972_r2.5.patch"

  if platform.is_cross_compiled?
    pkg.apply_patch "#{base}/uri_generic_remove_safe_nav_operator_r2.5.patch"
    pkg.apply_patch "#{base}/lib_optparse_remove_safe_nav_operator.patch"
    pkg.apply_patch "#{base}/revert_delete_prefix.patch"
    pkg.apply_patch "#{base}/remove_squiggly_heredocs.patch"
    pkg.apply_patch "#{base}/remove_deprecate_constant_statements.patch"
    pkg.apply_patch "#{base}/ruby2_keywords_guard.patch"
    pkg.apply_patch "#{base}/ruby_version_extra_guards.patch"
    pkg.apply_patch "#{base}/ruby_20_guards.patch"
    pkg.apply_patch "#{base}/deprecate_rubyforge_project_rubygems.patch"
    pkg.apply_patch "#{base}/rbinstall_gem_path.patch"
    pkg.apply_patch "#{base}/Replace-reference-to-RUBY-var-with-opt-pl-build-tool.patch"
  end

  if platform.is_aix?
    # TODO: Remove this patch once PA-1607 is resolved.
    pkg.apply_patch "#{base}/aix_configure.patch"
    pkg.apply_patch "#{base}/aix-fix-libpath-in-configure.patch"
    pkg.apply_patch "#{base}/aix_use_pl_build_tools_autoconf_r2.5.patch"
    pkg.apply_patch "#{base}/aix_ruby_2.1_fix_make_test_failure_r2.5.patch"
    pkg.apply_patch "#{base}/Remove-O_CLOEXEC-check-for-AIX-builds_r2.5.patch"
  end

  if platform.is_windows?
    pkg.apply_patch "#{base}/windows_ruby_2.5_fixup_generated_batch_files.patch"
    pkg.apply_patch "#{base}/windows_socket_compat_error_r2.5.patch"
    pkg.apply_patch "#{base}/windows_nocodepage_utf8_fallback_r2.5.patch"
    pkg.apply_patch "#{base}/windows_env_block_size_limit.patch"
  end

  ####################
  # ENVIRONMENT, FLAGS
  ####################

  if platform.is_macos?
    pkg.environment 'optflags', settings[:cflags]
  elsif platform.is_windows?
    pkg.environment 'optflags', settings[:cflags] + ' -O3'
  elsif platform.is_cross_compiled?
    pkg.environment 'CROSS_COMPILING', 'true'
  else
    pkg.environment 'optflags', '-O2'
  end

  special_flags = " --prefix=#{ruby_dir} --with-opt-dir=#{settings[:prefix]} "

  if platform.name =~ /sles-15|el-8|debian-10/ || (platform.is_fedora? && platform.os_version.to_i >= 29)
    special_flags += " CFLAGS='#{settings[:cflags]}' LDFLAGS='#{settings[:ldflags]}' CPPFLAGS='#{settings[:cppflags]}' "
  end

  if platform.is_aix?
    # This normalizes the build string to something like AIX 7.1.0.0 rather
    # than AIX 7.1.0.2 or something
    special_flags += " --build=#{settings[:platform_triple]} "
  elsif platform.is_cross_compiled_linux?
    special_flags += " --with-baseruby=#{host_ruby} "
  elsif platform.is_solaris? && platform.architecture == "sparc"
    special_flags += " --with-baseruby=#{host_ruby} --enable-close-fds-by-recvmsg-with-peek "
  elsif platform.is_windows?
    special_flags = " CPPFLAGS='-DFD_SETSIZE=2048' debugflags=-g --prefix=#{ruby_dir} --with-opt-dir=#{settings[:prefix]} "
  end

  without_dtrace = [
    'aix-6.1-ppc',
    'aix-7.1-ppc',
    'el-7-ppc64le',
    'el-7-aarch64',
    'redhatfips-7-x86_64',
    'sles-12-ppc64le',
    'solaris-11-sparc',
    'ubuntu-16.04-ppc64el',
    'windows-2012r2-x64',
    'windows-2012r2-x86',
    'windowsfips-2012r2-x64'
  ]

  unless without_dtrace.include? platform.name
    special_flags += ' --enable-dtrace '
  end

  ###########
  # CONFIGURE
  ###########

  # TODO: Remove this once PA-1607 is resolved.
  # TODO: Can we use native autoconf? The dependencies seemed a little too extensive
  pkg.configure { ["/opt/pl-build-tools/bin/autoconf"] } if platform.is_aix?

  # Here we set --enable-bundled-libyaml to ensure that the libyaml included in
  # ruby is used, even if the build system has a copy of libyaml available
  pkg.configure do
    [
      "bash configure \
        --enable-shared \
        --enable-bundled-libyaml \
        --disable-install-doc \
        --disable-install-rdoc \
        #{settings[:host]} \
        #{special_flags}"
    ]
  end

  #########
  # INSTALL
  #########

  if platform.is_windows?
    # With ruby 2.5, ruby will generate cmd files instead of bat files; These
    # cmd wrappers work fine in our environment if they're just renamed as batch
    # files. Rake is omitted here on purpose - it retains the old batch wrapper.
    #
    # Note that this step must happen after the install step above.
    pkg.install do
      %w{erb gem irb rdoc ri}.map do |name|
        "mv #{ruby_bindir}/#{name}.cmd #{ruby_bindir}/#{name}.bat"
      end
    end
  end

  target_doubles = {
    'powerpc-ibm-aix6.1.0.0' => 'powerpc-aix6.1.0.0',
    'aarch64-redhat-linux' => 'aarch64-linux',
    'ppc64-redhat-linux' => 'powerpc64-linux',
    'ppc64le-redhat-linux' => 'powerpc64le-linux',
    'powerpc64le-suse-linux' => 'powerpc64le-linux',
    'powerpc64le-linux-gnu' => 'powerpc64le-linux',
    'i386-pc-solaris2.10' => 'i386-solaris2.10',
    'sparc-sun-solaris2.10' => 'sparc-solaris2.10',
    'i386-pc-solaris2.11' => 'i386-solaris2.11',
    'sparc-sun-solaris2.11' => 'sparc-solaris2.11',
    'arm-linux-gnueabihf' => 'arm-linux-eabihf',
    'arm-linux-gnueabi' => 'arm-linux-eabi',
    'x86_64-w64-mingw32' => 'x64-mingw32',
    'i686-w64-mingw32' => 'i386-mingw32'
  }
  if target_doubles.key?(settings[:platform_triple])
    rbconfig_topdir = File.join(ruby_dir, 'lib', 'ruby', '2.7.0', target_doubles[settings[:platform_triple]])
  else
    rbconfig_topdir = "$$(#{ruby_bindir}/ruby -e \"puts RbConfig::CONFIG[\\\"topdir\\\"]\")"
  end

  rbconfig_changes = {}
  if platform.is_aix?
    rbconfig_changes["CC"] = "gcc"
  elsif platform.is_cross_compiled? || platform.is_solaris?
    rbconfig_changes["CC"] = "gcc"
    rbconfig_changes["warnflags"] = "-Wall -Wextra -Wno-unused-parameter -Wno-parentheses -Wno-long-long -Wno-missing-field-initializers -Wno-tautological-compare -Wno-parentheses-equality -Wno-constant-logical-operand -Wno-self-assign -Wunused-variable -Wimplicit-int -Wpointer-arith -Wwrite-strings -Wdeclaration-after-statement -Wimplicit-function-declaration -Wdeprecated-declarations -Wno-packed-bitfield-compat -Wsuggest-attribute=noreturn -Wsuggest-attribute=format -Wno-maybe-uninitialized"
    if platform.name =~ /el-7-ppc64/
      # EL 7 on POWER will fail with -Wl,--compress-debug-sections=zlib so this
      # will remove that entry
      # Matches both endians
      rbconfig_changes["DLDFLAGS"] = "-Wl,-rpath=/opt/puppetlabs/puppet/lib -L/opt/puppetlabs/puppet/lib  -Wl,-rpath,/opt/puppetlabs/puppet/lib"
    end
  elsif platform.is_windows?
    rbconfig_changes["CC"] = "x86_64-w64-mingw32-gcc"
  end

  pkg.add_source("file://resources/files/ruby_vendor_gems/operating_system.rb")
  defaults_dir = File.join(settings[:libdir], "ruby/2.7.0/rubygems/defaults")
  pkg.directory(defaults_dir)
  pkg.install_file "../operating_system.rb", File.join(defaults_dir, 'operating_system.rb')

  pkg.add_source("file://resources/files/rubygems/COMODO_RSA_Certification_Authority.pem")
  defaults_dir = File.join(settings[:libdir], "ruby/2.7.0/rubygems/ssl_certs/puppetlabs.net")
  pkg.directory(defaults_dir)
  pkg.install_file "../COMODO_RSA_Certification_Authority.pem", File.join(defaults_dir, 'COMODO_RSA_Certification_Authority.pem')

  if rbconfig_changes.any?
    pkg.install do
      [
        "#{host_ruby} ../rbconfig-update.rb \"#{rbconfig_changes.to_s.gsub('"', '\"')}\" #{rbconfig_topdir}",
        "cp original_rbconfig.rb #{settings[:datadir]}/doc/rbconfig-#{pkg.get_version}-orig.rb",
        "cp new_rbconfig.rb #{rbconfig_topdir}/rbconfig.rb",
      ]
    end
  end
end
