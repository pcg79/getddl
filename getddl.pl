#!/usr/bin/env perl
use strict;
use warnings;

# getddl, a script for managing postgresql schema via svn
# Copyright 2008, OmniTI, Inc. (http://www.omniti.com/)
# See complete license and copyright information at the bottom of this script  
# For newer versions of this script, please see:
# https://labs.omniti.com/trac/pgsoltools/wiki/getddl
# POD Documentation also available by issuing pod2text getddl.pl


use DirHandle;
use English qw( -no_match_vars);
use File::Path 'mkpath';
use File::Copy;
use Getopt::Long qw( :config no_ignore_case );

#### must be manually set. no cmdl options
#my $dbusername = 'postgres';
#Note: must use .pgpass if password is required or trusted user
#my $dbport = "5432";
# Set if using svn
my $svnuser = "--username postgres --password #####";

# TODO Turn into cmdl option
#my $pgdump="/opt/pgsql/bin/pg_dump ";
#my $pgrestore = "/opt/pgsql/bin/pg_restore ";
#### end manual settings

#my $host = "";
#my ($DO_SVN, $QUIET, $DDL_BASE) = (0, 0, './');
#my ($GET_TABLES, $GET_FUNCS, $GET_VIEWS, $SQL_DUMP, $GET_ALL) = (0, 0, 0, 0, 0);
#my ($DSN, $basedir, $dbname, $dbh);
my $dmp_tmp_file = "/tmp/pgdump".(time).".$$";

my $tmp_ddl_file = "/tmp/pgdump_ddl".(time).".$$";
my ($excludeschema, $excludeschema_file, $excludeschema_dump) = ("", "", "");
my ($includeschema, $includeschema_file, $includeschema_dump) = ("", "", "");
my ($excludetable, $excludetable_file, $excludetable_dump) = ("", "", "");
my ($includetable, $includetable_file, $includetable_dump) = ("", "", "");
#my ($excludeview, $excludeview_file) = ("", "");
#my ($includeview, $includeview_file) = ("", "");
my (@includeview, @excludeview);
#my ($excludefunction, $excludefunction_file) = ("", "");
#my ($includefunction, $includefunction_file) = ("", ""); 
my (@includefunction, @excludefunction);
#my ($excludeowner, $excludeowner_file) = ("", "");
#my ($includeowner, $includeowner_file) = ("", "");
my (@includeowner, @excludeowner);
my (@tablelist, @viewlist, @functionlist, @acl_list);

my $svn = '/opt/omni/bin/svn';
my $commit_msg = 'Pg ddl updates';
my $do_svn_del = 0;
my (@to_commit, @to_add);
my $commit_msg_fn = "";


################ Run main program subroutines
#my $start_time = time();
#sub elapsed_time { return time() - $start_time; }

my $O = get_options();

validate_options();

print "Creating temp dump...\n";
create_temp_dump();

print "Building object lists...\n";
build_object_lists();

# TODO Doublecheck tables are getting triggers exported.
print "Creating table ddl files...\n";
if (@tablelist) { create_ddl_files(\@tablelist, "tables");    }
print "Creating view ddl files...\n";
if (@viewlist) { create_ddl_files(\@viewlist, "views");    }  
print "Creating function ddl files...\n";
if (@functionlist) { create_ddl_files(\@functionlist, "functions"); }    

print "Creating pg_dump file...\n";
if ($O->{sqldump}) {
    copy_sql_dump();
}

print "Cleaning up...\n";
cleanup();

exit;
#print "Cleaned up and finished exporting $dbname ddl after " . elapsed_time() . " seconds.\n";
############################


# TODO Look through pg_restore options and add more here
# TODO See if role export can be done
sub get_options {
    # TODO get ENV variables for postgres to set defaults
    my %o = (
        'dbusername' => "postgres", 
        'port' => 5432,
        'pgdump' => "/opt/pgsql/bin/pg_dump",
        'pgrestore' => "/opt/pgsql/bin/pg_restore",
        'ddlbase' => "./",
        
        'dosvn' => undef,
    
    );
    show_help_and_die() unless GetOptions(
        \%o,
        'ddlbase=s',
        'host=s',
        'port|p=i',
        'dbname=s',
        'quiet!',
        'gettables!',
        'getviews!',
        'getfuncs!',
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
        'svn!',
        'svndel',
        'svndir=s',
        'commitmsg=s',
        'commitmsgfn=s',
        
        'help|?',
    );
    show_help_and_die() if $o{'help'};
    return \%o;
}

sub validate_options {
    
    # TODO remove database name requirement and use ENV
    show_help_and_die("Database name required. Please set --dbname\n") unless ($O->{'dbname'}); 
    #if (!$dbname) { die "Database name required. Please set --dbname\n"; }

    if (!$O->{'gettables'} && !$O->{'getfuncs'} && !$O->{'getviews'}) {
        if ($O->{'getall'}) {
            $O->{'gettables'} = 1;
            $O->{'getfuncs'} = 1;
            $O->{'getviews'} = 1;
        } elsif ($O->{'sqldump'}) {
            die "Only pg_dump set. Please consider running pg_dump by itself instead.\n";    
        } else {
            die "No output options set. Please set one or more of the following: --gettables, --getviews, --getprocs. Or --getall for all 3.\n";
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
     
    my $real_server_name=`hostname`;
    my $customhost;
    if ($O->{'host'}) {
        $customhost = $O->{'host'};
    } else {
        $customhost = chomp($real_server_name);
    }
    $O->{'basedir'} = "$O->{ddlbase}/$customhost/$O->{dbname}";


    if ($O->{'N'} || $O->{'N_file'} || $O->{'T'} || $O->{'T_file'} || 
            $O->{'V'} || $O->{'V_file'} || $O->{'P_file'}) {
        print "Building exclude lists...\n";
        build_excludes();
    }
    if ($O->{'n'} || $O->{'N_file'} || $O->{'t'} || $O->{'t_file'} || 
            $O->{'v'} || $O->{'v_file'} || $O->{'p_file'}) {
        print "Building include lists...\n";
        build_includes();
    }
}




sub create_temp_dump {
    # add option for remote hostname
    my $pgdumpcmd = "$O->{pgdump} -s -Fc -U $O->{dbusername} -p $O->{port} ";

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
    print "$pgdumpcmd $O->{dbname} > $dmp_tmp_file\n";  
    system "$pgdumpcmd $O->{dbname} > $dmp_tmp_file";
}

sub build_excludes {
    my @list;
    my $count;
    if($O->{'N'} =~ /,/) {
        @list = split(',', $O->{'N'});
        for($count=0; $count < scalar(@list); $count++) {
            $excludeschema_dump .= "-N".$list[$count]." ";
        }
    } else {
      $excludeschema_dump = "-N".$O->{'N'} unless !$O->{'N'};
    }
    
    if ($O->{'T'} =~ /,/) {
        @list = split(',', $O->{'T'});
        for ($count=0; $count < scalar(@list); $count++) {
            $excludetable_dump .= "-T".$list[$count]." ";
        }
    } else {
        $excludetable_dump = "-T".$O->{'T'} unless !$O->{'T'};
    }
    
    if ($O->{'V'} =~ /,/) {
        @excludeview = split(',', $O->{'V'});
    } elsif ($O->{'V'}) {
        push @excludeview, $O->{'V'};
    }
    
     if ($O->{'O'}=~ /,/) {
        @excludeowner = split(',', $O->{'O'});
     } elsif ($O->{'O'}) {
        push @excludeowner, $O->{'O'};
     }
    
    if ($O->{'N_file'}) {
        open SCHEMAFILE, $O->{'N_file'} or die_cleanup("Cannot open exclude file for reading [$O->{N_file}]: $!");
        while(<SCHEMAFILE>) {
            chomp;
            $excludeschema_dump .= "-N".$_." ";
        }
        close SCHEMAFILE;
    }
    
    if ($O->{'T_file'}) {
        open TABLEFILE, $O->{'T_file'} or die_cleanup("Cannot open exclude file for reading [$O->{T_file}]: $!");
        while(<TABLEFILE>) {
            chomp;
            $excludetable_dump .= "-T".$_." ";
        }
        close TABLEFILE;
    }
    
    if ($O->{'V_file'}) {
        open VIEWFILE, $O->{'V_file'} or die_cleanup("Cannot open exclude file for reading [$O->{V_file}]: $!");
        while(<VIEWFILE>) {
            chomp;
            push @excludeview, $_;
        }
        close VIEWFILE;
    }
    
    if ($O->{'P_file'}) {
        open FUNCTIONFILE, $O->{'P_file'} or die_cleanup("Cannot open exclude file for reading [$O->{P_file}]: $!");
        while(<FUNCTIONFILE>) {
            chomp;
            push @excludefunction, $_;
        }
        close FUNCTIONFILE;
    }
    
    if ($O->{'O_file'}) {
        open OWNERFILE, $O->{'O_file'} or die_cleanup("Cannot open exclude file for reading [$O->{O_file}]: $!");
        while (<OWNERFILE>) {
            chomp;
            push @excludeowner, $_;
        }
        close OWNERFILE;
    }
}

sub build_includes {
    my @list;
    my $count;
    if ($O->{'n'} =~ /,/) {
        @list = split(',', $O->{'n'});
        for($count=0; $count < scalar(@list); $count++) {
            $includeschema_dump .= "-n".$list[$count]." ";
        }
    } else {
        $includeschema_dump = "-n".$O->{'n'} unless !$O->{'n'}; 
    }
    
    if (defined($O->{'t'}) && $O->{'t'} =~ /,/) {
        @list = split(',', $O->{'t'});
        for ($count=0; $count <scalar(@list); $count++) {
            $includetable_dump .= "-t".$list[$count]." ";
        }
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
        open SCHEMAFILE, $O->{'n_file'} or die_cleanup("Cannot open include file for reading [$O->{n_file}]: $!");
        while(<SCHEMAFILE>) {
            chomp;
            $includeschema_dump .= "-n".$_." ";
        }
        close SCHEMAFILE;
    }
    
    if ($O->{'t_file'}) {
        open TABLEFILE, $O->{'t_file'} or die_cleanup("Cannot open include file for reading [$O->{t_file}]: $!");
        while(<TABLEFILE>) {
            chomp;
            $includetable_dump .= "-t".$_." ";
        }
        close TABLEFILE;
    }
    
    if ($O->{'v_file'}) {
        open VIEWFILE, $O->{'v_file'} or die_cleanup("Cannot open include file for reading [$O->{v_file}]: $!");
        while(<VIEWFILE>) {
            chomp;
            push @includeview, $_;
        }
        close VIEWFILE;
    }
    
    if ($O->{'p_file'}) {
        open FUNCTIONFILE, $O->{'p_file'} or die_cleanup("Cannot open include file for reading [$O->{p_file}]: $!");
        while(<FUNCTIONFILE>) {
            chomp;
            push @includefunction, $_;
        }
        close FUNCTIONFILE;
    }
    
    if ($O->{'o_file'}) {
        open OWNERFILE, $O->{'o_file'} or die_cleanup("Cannot open include file for reading [$O->{o_file}]: $!");
        while(<OWNERFILE>) {
            chomp;
            push @includeowner, $_;
        }
        close OWNERFILE;
    }
}

sub build_regex_filters {

    # TODO: These filters will have to be applied during the restore playback
    
}


sub build_object_lists {
    my $restorecmd = "$O->{pgrestore} -l $dmp_tmp_file";
    my ($objid, $objtype, $objschema, $objname_owner, $objname, $objowner, $key, $value);
    my (%table_h, %view_h, %function_h, %acl_h);
    
    foreach (`$restorecmd`) {
        if (/^;/) {
            next;
        }
        if (/[\(\)]/) {
            ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(.*\))\s(\S+)/;
        } else {
            ($objid, $objtype, $objschema, $objname, $objowner) = /(\d+;\s\d+\s\d+)\s(\S+)\s(\S+)\s(\S+)\s(\S+)/;
        }
        # TODO add in object filtering (named & regex) options here
       
        if ($O->{'gettables'} && $objtype eq "TABLE") {
            %table_h = (
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            );
            push @tablelist, {%table_h};
        }

        if ($O->{'getviews'} && $objtype eq "VIEW") {
            %view_h = (
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            );
            push @viewlist, {%view_h};
        }

        if ($O->{'getfuncs'} && $objtype eq "FUNCTION") {
            %function_h = (
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            );
            push @functionlist, {%function_h};
        }
    
        if ($objtype eq "ACL") {
            %acl_h = (
                "id" => $objid,
                "type" => $objtype,
                "schema" => $objschema,
                "name" => $objname,
                "owner" => $objowner,
            );
          
            push @acl_list, {%acl_h};
        }
        
    } # end restorecmd if    
} # end build_object_lists

sub create_dirs {
    my $newdir = shift @_;
    
    my $destdir = "$O->{basedir}/$newdir";
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
    my ($restorecmd, $dumpcmd, $fqfn, $funcname);
    my $fulldestdir = create_dirs($destdir);
    
    my $list_file_contents = "";
        
    foreach my $t (@objlist) {
        
        print "objlist: $t->{id} $t->{type} $t->{schema} $t->{name} $t->{owner}\n";
        
        if ($t->{'name'} =~ /\(.*\)/) {
            $funcname = substr($t->{'name'}, 0, index($t->{'name'}, "\("));
            $fqfn = "$fulldestdir/$t->{schema}.$funcname";
        } else {
            $fqfn = "$fulldestdir/$t->{schema}.$t->{name}";
        }
        
        $list_file_contents = "$t->{id} $t->{type} $t->{schema} $t->{name} $t->{owner}\n";
        
        if ($t->{'type'} eq "TABLE") {
            $dumpcmd = "$O->{pgdump} -U $O->{dbusername} -p $O->{port} -s -Fp -t$t->{schema}.$t->{name} $O->{dbname} > $fqfn.sql";
            system $dumpcmd;
        } else {
            # TODO this is a mess but, amazingly, it works. try and tidy up if possible.
            # put all functions with same basename in the same output file 
            # along with each function's ACL following just after it.
            if ($t->{'type'} eq "FUNCTION") {
                # add to current file output if first found of object has an ACL
                foreach (@acl_list) {
                    if ($_->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{name} $_->{owner}\n";
                    }
                }
                my $dupefunc;
                my $offset = 0;
                # loop through again to find dupes (overloads)
                foreach my $d (@objlist) {
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
                        # if duplicate found, remove from looped function list so it doesn't get output again.
                        splice(@objlist,$offset,1)
                    }
                    $offset++;
                }
            } else {
                # add to current file output if this object has an ACL
                foreach (@acl_list) {
                    if ($_->{'name'} eq $t->{'name'}) {
                        $list_file_contents .= "$_->{id} $_->{type} $_->{schema} $_->{name} $_->{owner}\n";
                    }
                }
            }
            open LIST, ">", $tmp_ddl_file or die_cleanup("could not create required temp file [$tmp_ddl_file]: $!\n");
            print "$list_file_contents\n";
            print LIST "$list_file_contents";
            $restorecmd = "$O->{pgrestore} -s -L $tmp_ddl_file -f $fqfn.sql $dmp_tmp_file";
            system $restorecmd;
            close LIST;
        }
        chmod 0664, $fqfn;
    }
}

sub copy_sql_dump {
    my $dump_folder = create_dirs("pg_dump");
    my $pgdumpfile = "$dump_folder/$O->{dbname}_pgdump.pgr";
    copy ($dmp_tmp_file, $pgdumpfile);
}

sub die_cleanup {
    my $message = shift @_;
    cleanup();
    die "$message\n";
}

sub cleanup {
    #$dbh->disconnect();
    
    if (-e $tmp_ddl_file) { unlink $tmp_ddl_file; }
    if (-e $dmp_tmp_file) { unlink $dmp_tmp_file; }
   
}


# TODO From old getddl. Redo to read output of svn status on basedir.
sub svn_check {
    my (%args) = @_;
    my $fn = create_dirs($args{destdir});
    $fn .= "/$args{fqn}.sql";

    #print "  * comparing $args{fqn}\n" if not $O->{quiet};
    # svn st, ? = add, m = commit
    my $svnst = `$args{svn} st $svnuser $fn`;
    for my $line (split "\n", $svnst) {
        next if $line !~ /\.sql$/;
        if ($line =~ /^\?\s+(\S+)$/) {
            print "svn add: $fn\n" if not $O->{quiet};
            push @{$args{to_add}}, $fn;           
        } elsif ($line =~ /^[M|A]\s+\Q$fn/) {
            print "svn modified: $fn\n" if not $O->{quiet};
            push @{$args{to_commit}}, $fn;
        }
    }
}
    



# TODO: Do svn status on folder and read that output instead of comparing each individual file
# Match on M, A, D, ? statuses for each file and act appropriately
if ($O->{'dosvn'}) {
    
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

sub show_help_and_die {
 	    my ( $format, @args ) = @_;
 	    if ( defined $format ) {
 	        $format =~ s/\s*\z/\n/;
 	        printf STDERR $format, @args;
 	    }
 	    print STDERR <<_EOH_;
    Syntax:
        $PROGRAM_NAME [options]
 	
 	Options:
        [ database connection ]
        --host                  (-h) : database server host or socket directory
        --port                  (-p) : database server port
        --user                  (-U) : database user name
        --dbname                (-d) : database name to connect to

        [ other ]
        
        --help                  (-?) : show this help page
 	
 	Defaults:
        --exclude-schema   '^(pg_.*|information_schema)\$'
 	   
 	
 	Notes:
 	    
_EOH_
    exit 1;
}

=head1 NAME

getddl - a ddl to svn script for postgres

=head1 SYNOPSIS

A perl script to query a postgres database, write schema to file, and then check in said files. 

=head1 VERSION

This document refers to version 0.5.1 of getddl, released January 30, 2009

=head1 USAGE

To use getddl, you need to configure several variables inside the script (mostly having to do with different connection options). If dumping multiple databases, 
the role you define in the configuration will have to have <<<find actual privs needed>>> privileges on all databases.

Once configured, you call gettdll at the command line. 

Example 1: grab ddl for both the tables and function and dump it to /db/schema/ridley, check-in any modifications or new objects, and remove any entries that no longer exist in svn. 

    perl /home/postgres/getddl.pl --host ridley  --ddlbase /db/schema/ --getddl --getprocs --svn --svndel >>  /home/postgres/logs/getddl.log

Example 2: grab ddl of only database functions and dump them to /db/schema/kraid/function.

    perl /home/postgres/getddl.pl --host kraid --ddlbase /db/schema --getprocs 


=head1 BUGS AND LIMITATIONS

Some actions may not work on older versions of Postgres (before 8.1).

Please report any problems to robert@omniti.com.

=head1 TODO

=over 

=item * clean up / optimize iteration for items in svn lists

=item * clean-up default hosts directives

=item * validate config options vs. command line options

=item * add support for other rcs systems

=back

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
