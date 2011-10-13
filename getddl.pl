#!/usr/bin/env perl
use strict;
use warnings;

# getddl, a script for managing postgresql schema via svn
# Copyright 2008, OmniTI, Inc. (http://www.omniti.com/)
# See complete license and copyright information at the bottom of this script  
# For newer versions of this script, please see:
# https://github.com/keithf4/getddl
# POD Documentation also available by issuing pod2text getddl.pl


use DirHandle;
use English qw( -no_match_vars);
use File::Copy;
use File::Path 'mkpath';
use File::Spec;
use File::Temp;
use Getopt::Long qw( :config no_ignore_case );
use Sys::Hostname;



my ($excludeschema_dump, $includeschema_dump, $excludetable_dump, $includetable_dump) = ("","","","");
my (@includeview, @excludeview);
my (@includefunction, @excludefunction);
my (@includeowner, @excludeowner);
my (@tablelist, @viewlist, @functionlist, @typelist, @acl_list, @commentlist);

# For future svn stuff
#my (@to_commit, @to_add);
#my $svnuser = "--username postgres --password #####";


################ Run main program subroutines
#my $start_time = time();
#sub elapsed_time { return time() - $start_time; }

my $O = get_options();

set_config();

create_dirs();
# TODO change to TMPDIR option. 
my $dmp_tmp_file = File::Temp->new( TEMPLATE => 'getddl_XXXXXXX', 
                                    SUFFIX => '.tmp',
                                    DIR => $O->{'basedir'});

print "Creating temp dump...\n";
create_temp_dump();

print "Building object lists...\n";
build_object_lists();


if (@tablelist) { 
    print "Creating table ddl files...\n";
    create_ddl_files(\@tablelist, "tables");    
}

if (@viewlist) { 
    print "Creating view ddl files...\n";
    create_ddl_files(\@viewlist, "views");   
}  

if (@functionlist) { 
    print "Creating function ddl files...\n";
    create_ddl_files(\@functionlist, "functions"); 
}    

if (@typelist) {
    print "Creating type ddl files...\n";
    create_ddl_files(\@typelist, "types");
}

print "Creating pg_dump file...\n";
if ($O->{sqldump}) {
    copy_sql_dump();
}

if ($O->{'dosvn'}) {
    
}

print "Cleaning up...\n";
cleanup();

exit;
#print "Cleaned up and finished exporting $dbname ddl after " . elapsed_time() . " seconds.\n";
############################


# TODO Look through pg_restore options and add more here
# TODO See if role export can be done
sub get_options {
    my %o = (
        'pgdump' => "pg_dump",
        'pgrestore' => "pg_restore",
        'ddlbase' => ".",
        
        'svn' => 'svn',
        'commit_msg' => 'Pg ddl updates',
    );
    show_help_and_die() unless GetOptions(
        \%o,
        'ddlbase=s',
        'username|U=s',
        'host|h=s',
        'hostname=s',
        'port|p=i',
        'pgpass=s',
        'dbname|d=s',
        'pgdump=s',
        'pgrestore=s',
        'quiet!',
        'gettables!',
        'getviews!',
        'getfuncs!',
        'gettypes!',
        'getall!',
        'sqldump!',
        'N=s',
        'N_file=s',
        'n=s',
        'n_file=s',
        'T=s',
        'T_file=s',
        't=s',
        't_file=s',
        'V=s',
        'V_file=s',
        'v=s',
        'v_file=s',
        'P_file=s',
        'p_file=s',
        'O=s',
        'o=s',
        'O_file=s',
        'o_file=s',
        
        'svn=s',
        'svndel!',
        'svndir=s',
        'commitmsg=s',
        'commitmsgfn=s',
        
        'help|?',
        'getdata!',    # leave as undocumented feature. shhh!
    );
    show_help_and_die() if $o{'help'};
    return \%o;
}

sub set_config {
    
    if ($O->{'dbname'}) { 
        $ENV{PGDATABASE} = $O->{'dbname'};
    }
    if ($O->{'port'}) {
        $ENV{PGPORT} = $O->{'port'};
    }
    if ($O->{'host'}) {
        $ENV{PGHOST} = $O->{'host'};
    }
    if ($O->{'username'}) {
        $ENV{PGUSER} = $O->{'username'};
    }
    if ($O->{'pgpass'}) {
        $ENV{PGPASSFILE} = $O->{'pgpass'};
    }

    if (!$O->{'gettables'} && !$O->{'getfuncs'} && !$O->{'getviews'} && !$O->{'gettypes'}) {
        if ($O->{'getall'}) {
            $O->{'gettables'} = 1;
            $O->{'getfuncs'} = 1;
            $O->{'getviews'} = 1;
            $O->{'gettypes'} = 1;
        } elsif ($O->{'sqldump'}) {
            die("NOTICE: Only pg_dump set. Please consider running pg_dump by itself instead.\n");
        } else {
            die("NOTICE: No output options set. Please set one or more of the following: --gettables, --getviews, --getprocs, --gettypes. Or --getall for all. Use --help to show all options\n");
        }
    }

    if (!$O->{'gettables'} && ($O->{'T'} || $O->{'T_file'} || $O->{'t'} || $O->{'t_file'})) {
        die "Cannot include/exclude tables without setting option to export tables (--gettables or --getall).\n";
    }

    if (!$O->{'getviews'} && ($O->{'V'} || $O->{'V_file'} || $O->{'v'} || $O->{'v_file'})) {
        die "Cannot include/exclude views without setting option to export views (--getviews or --getall).\n";
    }

    if (!$O->{'getfuncs'} && ($O->{'P_file'} || $O->{'p_file'})) {
        die "Cannot include/exclude functions without setting option to export functions (--getfuncs or --getall).\n";
    }

    # TODO Redo option combinations to work like check_postgres (exclude then include)
    #      Until then only allowing one or the other
    if ( (($O->{'n'} && $O->{'N'}) || ($O->{'n_file'} && $O->{'N_file'})) ||
            (($O->{'t'} && $O->{'T'}) || ($O->{'t_file'} && $O->{'T_file'})) ||
            (($O->{'v'} && $O->{'V'}) || ($O->{'v_file'} && $O->{'V_file'})) ||
            (($O->{'p_file'} && $O->{'P_file'})) ) {
        die "Cannot specify both include and exclude for the same object type (schema, table, view, function).\n";
    }
     
    my $real_server_name=hostname;
    my $customhost;
    if ($O->{'hostname'}) {
        $customhost = $O->{'hostname'};
    } else {
        chomp ($customhost = $real_server_name);
    }
    $O->{'basedir'} = File::Spec->catdir($O->{ddlbase}, $customhost, $ENV{PGDATABASE});


    if ($O->{'N'} || $O->{'N_file'} || $O->{'T'} || $O->{'T_file'} || 
            $O->{'V'} || $O->{'V_file'} || $O->{'P_file'} || $O->{'O'} || $O->{'O_file'}) {
        print "Building exclude lists...\n";
        build_excludes();
    }
    if ($O->{'n'} || $O->{'n_file'} || $O->{'t'} || $O->{'t_file'} || 
            $O->{'v'} || $O->{'v_file'} || $O->{'p_file'} || $O->{'o'} || $O->{'o_file'}) {
        print "Building include lists...\n";
        build_includes();
    }   
}

sub create_temp_dump {
    my $pgdumpcmd = "$O->{pgdump} -Fc ";
    
    if (!$O->{'getdata'}) {
        $pgdumpcmd .= "-s ";
    }
    if ($O->{'N'} || $O->{'N_file'}) {
        $pgdumpcmd .= "$excludeschema_dump ";
    }
    if ($O->{'n'} || $O->{'n_file'}) {
        $pgdumpcmd .= "$includeschema_dump ";
    }
    if ($O->{'T'} || $O->{'T_file'}) {
        $pgdumpcmd .= "$excludetable_dump ";
    }
    if ($O->{'t'} || $O->{'t_file'}) {
        $pgdumpcmd .= "$includetable_dump ";
    }
    
    print "$pgdumpcmd > $dmp_tmp_file\n";  
    system "$pgdumpcmd > $dmp_tmp_file";
}

sub build_excludes {
    my @list;
    my $fh;
    if(defined($O->{'N'}) && $O->{'N'} =~ /,/) {
        @list = split(',', $O->{'N'});
        $excludeschema_dump .= "-N".$_." " for @list;
    } else {
      $excludeschema_dump = "-N".$O->{'N'} unless !$O->{'N'};
    }
    
    if (defined($O->{'T'}) && $O->{'T'} =~ /,/) {
        @list = split(',', $O->{'T'});
        $excludetable_dump .= "-T".$_." " for @list;
    } else {
        $excludetable_dump = "-T".$O->{'T'} unless !$O->{'T'};
    }
    
    if (defined($O->{'V'}) && $O->{'V'} =~ /,/) {
        @excludeview = split(',', $O->{'V'});
    } elsif ($O->{'V'}) {
        push @excludeview, $O->{'V'};
    }
    
     if (defined($O->{'O'}) && $O->{'O'} =~ /,/) {
        @excludeowner = split(',', $O->{'O'});
     } elsif ($O->{'O'}) {
        print "\$O->{O} : $O->{'O'}\n";
        push @excludeowner, $O->{'O'};
     }
    
    if ($O->{'N_file'}) {
        open $fh, "<", $O->{'N_file'} or die_cleanup("Cannot open exclude file for reading [$O->{N_file}]: $!");
        while(<$fh>) {
            chomp;
            $excludeschema_dump .= "-N".$_." ";
        }
        close $fh;
    }
    
    if ($O->{'T_file'}) {
        open $fh, "<", $O->{'T_file'} or die_cleanup("Cannot open exclude file for reading [$O->{T_file}]: $!");
        while(<$fh>) {
            chomp;
            $excludetable_dump .= "-T".$_." ";
        }
        close $fh;
    }
    
    if ($O->{'V_file'}) {
        open $fh, "<", $O->{'V_file'} or die_cleanup("Cannot open exclude file for reading [$O->{V_file}]: $!");
        while(<$fh>) {
            chomp;
            push @excludeview, $_;
        }
        close $fh;
    }
    
    if ($O->{'P_file'}) {
        open $fh, "<", $O->{'P_file'} or die_cleanup("Cannot open exclude file for reading [$O->{P_file}]: $!");
        while(<$fh>) {
            chomp;
            push @excludefunction, $_;
        }
        close $fh;
    }
    
    if ($O->{'O_file'}) {
        open $fh, "<", $O->{'O_file'} or die_cleanup("Cannot open exclude file for reading [$O->{O_file}]: $!");
        while (<$fh>) {
            chomp;
            push @excludeowner, $_;
        }
        close $fh;
    }
}

sub build_includes {
    my @list;
    my $fh;
    if (defined($O->{'n'}) && $O->{'n'} =~ /,/) {
        @list = split(',', $O->{'n'});
        $includeschema_dump .= "-n".$_." " for @list;
    } else {
        $includeschema_dump = "-n".$O->{'n'} unless !$O->{'n'}; 
    }
    
    if (defined($O->{'t'}) && $O->{'t'} =~ /,/) {
        @list = split(',', $O->{'t'});
        $includetable_dump .= "-t".$_." " for @list;
    } else {
        $includetable_dump = "-t".$O->{'t'} unless !$O->{'t'};
    }
    
    if (defined($O->{'v'}) && $O->{'v'} =~ /,/) {
        @includeview = split(',', $O->{'v'});
    } elsif ($O->{'v'}) {
        push @includeview, $O->{'v'};
    } 
    
    if (defined($O->{'o'}) && $O->{'o'} =~ /,/) {
        @includeowner = split(',', $O->{'o'});
    } elsif ($O->{'o'}) {
        push @includeowner, $O->{'o'};
    }
    
    if ($O->{'n_file'}) {
        open $fh, "<", $O->{'n_file'} or die_cleanup("Cannot open include file for reading [$O->{n_file}]: $!");
        while(<$fh>) {
            chomp;
            $includeschema_dump .= "-n".$_." ";
        }
        close $fh;
    }
    
    if ($O->{'t_file'}) {
        open $fh, "<", $O->{'t_file'} or die_cleanup("Cannot open include file for reading [$O->{t_file}]: $!");
        while(<$fh>) {
            chomp;
            $includetable_dump .= "-t".$_." ";
        }
        close $fh;
    }
    
    if ($O->{'v_file'}) {
        open $fh, "<", $O->{'v_file'} or die_cleanup("Cannot open include file for reading [$O->{v_file}]: $!");
        while(<$fh>) {
            chomp;
            push @includeview, $_;
        }
        close $fh;
    }
    
    if ($O->{'p_file'}) {
        open $fh, "<", $O->{'p_file'} or die_cleanup("Cannot open include file for reading [$O->{p_file}]: $!");
        while(<$fh>) {
            chomp;
            push @includefunction, $_;
        }
        close $fh;
    }
    
    if ($O->{'o_file'}) {
        open $fh, "<", $O->{'o_file'} or die_cleanup("Cannot open include file for reading [$O->{o_file}]: $!");
        while(<$fh>) {
            chomp;
            push @includeowner, $_;
        }
        close $fh;
    }
}

sub build_regex_filters {

    # TODO: These filters will have to be applied during the restore playback
    
}


sub build_object_lists {
    my $restorecmd = "$O->{pgrestore} -l $dmp_tmp_file";
    my ($objid, $objtype, $objschema, $objsubtype, $objname, $objowner, $key, $value);
    
    
    RESTORE_LABEL: foreach (`$restorecmd`) {
        chomp;
        ##print "restorecmd result: $_ \n";
        if (/^;/) {
            next;
        }
        my ($typetest) = /\d+;\s\d+\s\d+\s+(.*)/;
        if ($typetest =~ /^TABLE|VIEW|TYPE|ACL/) {
            ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(\S+)\s(\S+)/;
        } elsif ($typetest =~ /^FUNCTION/) {
            ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(.*\))\s(\S+)/;
        } elsif ($typetest =~ /^COMMENT/) {
            
            ($objsubtype) = /\d+;\s\d+\s\d+\s\S+\s\S+\s(\S+)/;
            ##print "sub $objsubtype\n";
            
            if ($objsubtype eq "FUNCTION") {
                ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s\S+\s(.*\))\s(\S+)/;
                #split out base name
                
                ##print "$objname\n";
                #split out arguement list
                my $args = substr($objname, index($objname, "\(")+1, length($objname)-index($objname, "\(")-2);
                next RESTORE_LABEL if (!$args);
                $objname = substr($objname, 0, index($objname, "\(")+1);
                ##print "$objname\n";
                ##print "args: $args\n";
                ##print "index: " . index($objname, "\(") . "\n";
                ##print "length: ".length($objname)."\n";
                if ($args =~ /,/) {
                    my @args = split(', ', $args);
                    my $count = 0;
                    foreach (@args) {
                        # remove variable name if exists in function definition
                        if (/\S+\s(.*)/) {
                  ##          print "length args: ".scalar(@args)."\n";
                   ##         print "arg: $1\n";
                            $objname .= $1;
                            if ($count < scalar(@args)-1) {
                                $objname .= ", ";
                            }
                        } else {
                            $objname .= $_;
                        }
                        $count++;
                    }
                } else {
                    # remove variable name if exists in function definition
                    if ($args =~ /\S+\s(.*)/) {
                        $objname .= $1;
                    } else {
                        $objname .= $args;
                    }
                }
                
                $objname .= ")";
               # print "new: $objname\n";
            } else {
                ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s\S+\s(\S+)\s(\S+)/;
                next RESTORE_LABEL;
            }
        } else {
            next RESTORE_LABEL;
        }
        #if (/[\(\)]/) {
        #    ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(.*\))\s(\S+)/;
        #} else {
        #    ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(\S+)\s(\S+)/;
        #}
        
        ## Leave this test here. Not sure if bug it fixed is gone
        #if (!$objtype) {
        #    next;
        #}
        
       ## print "build list: \$objid: $objid, \$objtype : $objtype, \$objschema : $objschema, \$objname : $objname, \$objowner : $objowner\n";
        # TODO add in object regex filter options here

        if (@excludeowner) {
            foreach (@excludeowner) {
                next RESTORE_LABEL if ($_ eq $objowner);
            }
        }
        
        if (@includeowner) {
            foreach (@includeowner) {
                next RESTORE_LABEL if ($_ ne $objowner);
            }
        }
       
        if ($O->{'gettables'} && $objtype eq "TABLE") {
            push @tablelist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }

        if ($O->{'getviews'} && $objtype eq "VIEW") {
            if (@excludeview) {
                foreach (@excludeview) {
                    if ($_ =~ /\./) {
                        next RESTORE_LABEL if($_ eq "$objschema.$objname");
                    } elsif ($_ eq $objname) {
                        next RESTORE_LABEL;
                    }
                }
            }
            if (@includeview) {
                my $found = 0;
                foreach (@includeview) {
                    if ($_ =~ /\./) {
                         if($_ ne "$objschema.$objname") {
                            next;
                         } else {
                            $found = 1;
                         }
                    } else {
                        if ($_ ne $objname) {
                            next;
                        } else {
                            $found = 1;
                        }
                    }
                }
                if (!$found) {
                    next RESTORE_LABEL;
                }
            }
            push @viewlist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }

        if ($O->{'getfuncs'} && $objtype eq "FUNCTION") {
            if (@excludefunction) {
                foreach (@excludefunction) {
                    if ($_ =~ /\./) {
                        next RESTORE_LABEL if($_ eq "$objschema.$objname");
                    } elsif ($_ eq $objname) {
                        next RESTORE_LABEL;
                    }
                }
            }
            
            if (@includefunction) {
                my $found = 0;
                foreach (@includefunction) {
                    if ($_ =~ /\./) {
                         if($_ ne "$objschema.$objname") {
                            next;
                         } else {
                            $found = 1;
                         }
                    } else {
                        if ($_ ne $objname) {
                            next;
                        } else {
                            $found = 1;
                        }
                    }
                }
                if (!$found) {
                    next RESTORE_LABEL;
                }
            }
            push @functionlist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }
        
        if ($objtype eq "TYPE") {
            push @typelist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }
        
        if ($objtype eq "COMMENT") {
            
            push @commentlist, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "subtype" => $objsubtype,
                "name" => $objname,
                "owner" => $objowner,
            };
        }
        
        if ($objtype eq "ACL") {
            push @acl_list, {
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            };
        }   
    } # end restorecmd if    
} # end build_object_lists

sub create_dirs {
    my $newdir = shift @_;
    
    my $destdir = File::Spec->catdir($O->{'basedir'}, $newdir);
    if (!-e $destdir) {
       eval { mkpath($destdir) };
       if ($@) {
            die_cleanup("Couldn't create base directory [$O->{basedir}]: $@");
        }
       print "created directory target [$destdir]\n";
    }
    return $destdir;   
}

#TODO: Delete files that are no longer part of schema if they exist from previous run
#       Only if svn not enabled
sub create_ddl_files {
    my (@objlist) = (@{$_[0]});
    my $destdir = $_[1];
    my ($restorecmd, $pgdumpcmd, $fqfn, $funcname);
    my $fulldestdir = create_dirs($destdir);
    my $tmp_ddl_file = File::Temp->new( TEMPLATE => 'getddl_XXXXXXXX', 
                                        SUFFIX => '.tmp',
                                        DIR => $O->{'basedir'});
    my $list_file_contents = "";
    my $offset = 0;
    
    foreach my $t (@objlist) {

        print "restore item: $t->{id} $t->{type} $t->{schema} $t->{name} $t->{owner}\n";
        
        if ($t->{'name'} =~ /\(.*\)/) {
            $funcname = substr($t->{'name'}, 0, index($t->{'name'}, "\("));
            my $schemafile = $t->{'schema'};
            my $namefile = $funcname;
            # account for special characters in object name
            $schemafile =~ s/(\W)/sprintf(",%02x", ord $1)/ge;;
            $namefile =~ s/(\W)/sprintf(",%02x", ord $1)/ge;;
            $fqfn = File::Spec->catfile($fulldestdir, "$schemafile.$namefile");
        } else {
            my $schemafile = $t->{'schema'};
            my $namefile = $t->{'name'};
            # account for special characters in object name
            $schemafile =~ s/(\W)/sprintf(",%02x", ord $1)/ge;;
            $namefile =~ s/(\W)/sprintf(",%02x", ord $1)/ge;;
            $fqfn = File::Spec->catfile($fulldestdir, "$schemafile.$namefile");
        }
        
        $list_file_contents = "$t->{id} $t->{type} $t->{schema} $t->{name} $t->{owner}\n";
        
        if ($t->{'type'} eq "TABLE") {
            $pgdumpcmd = "$O->{pgdump} ";
            if (!$O->{'getdata'}) {
                $pgdumpcmd .= "-s ";
            } 
            $pgdumpcmd .= "-Fp -t$t->{schema}.$t->{name} > $fqfn.sql";
            system $pgdumpcmd;
        } else {
            # TODO this is a mess but, amazingly, it works. try and tidy up if possible.
            # put all functions with same basename in the same output file 
            # along with each function's ACL & Comment following just after it.
            if ($t->{'type'} eq "FUNCTION") {
                my @dupe_objlist = @objlist;
                my $dupefunc;
                # add to current file output if first found of object has an ACL
                foreach (@acl_list) {
                    if ($_->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{name} $_->{owner}\n";
                    }
                }
                foreach (@commentlist) {
                    if ($_->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{subtype} $_->{name} $_->{owner}\n";
                    }
                }
                # loop through dupe of objlist to find overloads
                foreach my $d (@dupe_objlist) {
                    $dupefunc = substr($d->{'name'}, 0, index($d->{'name'}, "\("));
                    # if there is another function with the same name, but different signature, as this one ($t)...
                    if ($funcname eq $dupefunc && $t->{'name'} ne $d->{'name'}) {
                        # ...add overload of function ($d) to current file output
                        $list_file_contents .= "$d->{id} $d->{type} $d->{schema} $d->{name} $d->{owner}\n";
                        # add overloaded function's ACL if it exists
                        foreach (@acl_list) {
                            if ($_->{'name'} eq $d->{'name'}) {
                                $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{name} $_->{owner}\n";
                            }
                        }
                        foreach (@commentlist) {
                            if ($_->{'name'} eq $d->{'name'}) {
                                $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{subtype} $_->{name} $_->{owner}\n";
                            }
                        }                        
                        # if duplicate found, remove from main @objlist so it doesn't get output again.
                        splice(@objlist,$offset,1)
                    }
                }
            } else {
                
                # add to current file output if this object has an ACL
                foreach (@acl_list) {
                    if ($_->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{name} $_->{owner}\n";
                    }
                }
                foreach (@commentlist) {
                    if ($_->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{subtype} $_->{name} $_->{owner}\n";
                    }
                }       
            }
            open LIST, ">", $tmp_ddl_file or die_cleanup("could not create required temp file [$tmp_ddl_file]: $!\n");
            print "$list_file_contents\n";
            print LIST "$list_file_contents";
            $restorecmd = "$O->{pgrestore} -s -L $tmp_ddl_file -f $fqfn.sql $dmp_tmp_file";
            ##print "$restorecmd\n";
            system $restorecmd;
            close LIST;
        }
        chmod 0664, $fqfn;
        $offset++;
    }  # end @objlist foreach
}

sub copy_sql_dump {
    my $dump_folder = create_dirs("pg_dump");
    my $pgdumpfile = File::Spec->catfile($dump_folder, "$ENV{PGDATABASE}_pgdump.pgr");
    copy ($dmp_tmp_file->filename, $pgdumpfile);
}

sub die_cleanup {
    my $message = shift @_;
    cleanup();
    die "$message\n";
}

sub cleanup {
   # Was used to cleanup temp files. Keeping for now in case other cleanup is needed
}

sub show_help_and_die {
 	    my ( $format, @args ) = @_;
 	    if ( defined $format ) {
 	        $format =~ s/\s*\z/\n/;
 	        printf STDERR $format, @args;
 	    }
 	    print STDERR <<_EOH_;
 	    
    Syntax:
        $PROGRAM_NAME [options]
        
    Notes:
        - ONLY OPTIONS SHOWN HERE ARE READY FOR TESTING. Others seen in source may not work!
        - For all options that use an external file list, separate each item in the file by a newline.
        - If no schema name is given in an object filter, it will match across all schemas requested in the export.
        - If a special character is used in an object name, it will be replaced with a comma followed by its hexcode
            Ex: table|name becomes table,7cname.sql
        - Comments/Descriptions on any object should be included in the export file. If you see any missing, please contact the author
 	
 	Options:
        [ database connection ]
        --host          (-h) : database server host or socket directory
        --port          (-p) : database server port
        --username      (-U) : database user name
        --pgpass             : full path to location of .pgpass file
        --dbname        (-d) : database name to connect to
        
        [ directories ]
        --ddlbase           : base directory for ddl export
        --hostname          : hostname of the database server; used as directory name under --ddlbase
        --pgdump            : location of pg_dump executable
        --pgrestore         : location of pg_restore executable
        
        [ filters ]
        --gettables         : export table ddl. Each file includes table's indexes, constraints, sequences, comments, rules and triggers
        --getviews          : export view ddl 
        --getfuncs          : export function ddl. Overloaded functions will all be in the same base filename
        --gettypes          : export custom types.
        --getall            : gets all tables, views, functions and types. Shortcut to having to set all set.
        --N                 : csv list of schemas to EXCLUDE
        --N_file            : path to a file listing schemas to EXCLUDE.
        --n                 : csv list of schemas to INCLUDE
        --n_file            : path to a file listing schemas to INCLUDE.
        --T                 : csv list of tables to EXCLUDE. Schema name may be required (same for all table options)
        --T_file            : path to file listing tables to EXCLUDE.
        --t                 : csv list of tables to INCLUDE. Only these tables will be exported
        --t_file            : path to file listing tables to INCLUDE.
        --V                 : csv list of views to EXCLUDE. 
        --V_file            : path to file listing views to EXCLUDE.
        --v                 : csv list of views to INCLUDE. Only these views will be exported
        --v_file            : path to file listing views to INCLUDE. 
        --P_file            : path to file listing functions to EXCLUDE.
        --p_file            : path to file listing functions to INCLUDE.
        --O                 : csv list of object owners to EXCLUDE. Objects owned by these owners will NOT be exported
        --O_file            : path to file listing object owners to EXCLUDE. Objects owned by these owners will NOT be exported
        --o                 : csv list of object owners to INCLUDE. Only objects owned by these owners will be exported
        --o_file            : path to file listing object owners to INCLUDE. Only objects owned by these owners will be exported

        [ other ]
        --sqldump            : Also generate a pg_dump file. Will only contain schemas and tables designated by original options.
        --help          (-?) : show this help page
 	
 	Defaults:
        The following environment values are used: \$PGDATABASE, \$PGPORT, \$PGUSER, \$PGHOST, \$PGPASSFILE
        If not set and associated option is not passed, defaults will work the same as standard pg_dump.
        
        --ddlbase           '.'  (directory getddl is run from)
        --pgdump/restore    searches \$PATH 	    
_EOH_
    exit 1;
}

############# From old getddl ################

# TODO: Do svn status on folder and read that output instead of comparing each individual file
# Match on M, A, D, ? statuses for each file and act appropriately
sub svn_check {
    my (%args) = @_;
    my $fn = create_dirs($args{destdir});
    $fn .= "/$args{fqn}.sql";

    #print "  * comparing $args{fqn}\n" if not $O->{quiet};
    # svn st, ? = add, m = commit
    
    #my $svnst = `$args{svn} st $svnuser $fn`;
    #for my $line (split "\n", $svnst) {
    #    next if $line !~ /\.sql$/;
    #    if ($line =~ /^\?\s+(\S+)$/) {
    #        print "svn add: $fn\n" if not $O->{quiet};
    #        push @{$args{to_add}}, $fn;           
    #    } elsif ($line =~ /^[M|A]\s+\Q$fn/) {
    #        print "svn modified: $fn\n" if not $O->{quiet};
    #        push @{$args{to_commit}}, $fn;
    #    }
    #}
}
    
# TODO This is the old delete sub with the new array lists added. Most likely needs fixing
# TODO Also needs to account for sqldump
# Get a list of the files on disk to remove from disk.
# The files represent database objects. If there is a file that was
# not found in the scan of tables and procedure then the table or procedure
# has been removed and the file also has to go.
sub files_to_delete {
    # Double check that tables, procedures & views were scanned. If tables,
    # f'rinstance, were not scanned then all tables file would be deleted from
    # the filesystem. We don't want that.
    if (($O->{'gettables'} && scalar(@tablelist) == 0) || ($O->{'getfuncs'} && scalar(@functionlist) == 0) || ($O->{'getviews'} && scalar(@viewlist) == 0)) {
        print STDERR "The list of present tables, procedure, or views is incomplete.  We don't know for sure what to delete.\n";
        return undef;
    }
    # Make a hash of all the files representing the tables or procs on disk.
    my %file_list;
    my $dirh;
    
    if ($O->{'gettables'}) {
        $dirh = DirHandle->new($O->{'basedir'}."/table");
        while (defined(my $d = $dirh->read())) {
            $file_list{"table/$d"} = 1 if (-f "$O->{basedir}/table/$d" && $d =~ m/\.sql$/o);
        }
        # Go through the list of tables found in the database and remove the corresponding entry from the file_list.
        foreach my $f (@tablelist) {
            delete($file_list{"table/$f.sql"});
        }
    }

    if ($O->{'getfuncs'}) {
        $dirh = DirHandle->new($O->{'basedir'}."/function");
        while (defined(my $d = $dirh->read())) {
            $file_list{"function/$d"} = 1 if (-f "$O->{basedir}/function/$d" && $d =~ m/\.sql$/o);
        }
        foreach my $f (@functionlist) {
            delete($file_list{"function/$f.sql"});
        }
    }
    
    if ($O->{'getviews'}) {
        $dirh = DirHandle->new($O->{'basedir'}."/view");
        while (defined(my $d = $dirh->read())) {
        	$file_list{"view/$d"} = 1 if (-f "$O->{basedir}/function/$d" && $d =~ m/\.sql$/o);
        }
        foreach my $f (@viewlist) {
        	delete($file_list{"view/$f.sql"});
        }
    }
    
    # The files that are left in the %file_list are those for which the table
    # or procedure that they represent has been removed.
    my @files = map { "$O->{basedir}/$_" } keys(%file_list);
    return @files;
}


#TODO  Add POD docs here

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2008 OmniTI, Inc.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.

=cut
