# File::Takeput.pm
# Slurp style file IO with locking.
# (c) 2023 Bjørn Hee
# Licensed under the Apache License, version 2.0
# https://www.apache.org/licenses/LICENSE-2.0.txt

package File::Takeput;

use strict;
use experimental qw(signatures);
# use Exporter qw(import);

our $VERSION = 0.10;

use Fcntl qw(O_CREAT O_RDONLY O_RDWR O_WRONLY :flock);
use File::Basename qw(basename dirname);
use Cwd qw(abs_path);
use if $^O eq 'MSWin32' , 'File::Takeput::Win32';
use if $^O ne 'MSWin32' , 'File::Takeput::Unix';

my sub qwac( $s ) {grep{/./} map{split /\s+/} map{s/#.*//r} split/\v+/ , $s;};

our @EXPORT = qwac '
    append  # Append content to file.
    grab    # Read file content.
    pass    # Release the locks of a taken file.
    plunk   # Overwrite file with content.
    put     # Write to a taken file and release locks.
    take    # Take locks and read file content.
    ';

our @EXPORT_OK = qwac '
    fgrab  # Functional version of grab.
    fpass  # Functional version of pass.
    ftake  # Functional version of take.
    reset  # Reset default values.
    set    # Set default values.
    ';

# --------------------------------------------------------------------------- #
# Globals and defaults.

my $urdefault = {
    create => undef ,
    error => undef ,
    exclusive => undef ,
    newline => undef ,
    patience => 0 ,
    separator => $/ ,
    };
my $default;
$default = {$urdefault->%*};

my %imfh = (); # Hash for holding implicit filehandles.

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #

my $errh_msg;

my sub advice( $msg ) {
# Give an error advice (a warning pointing to the caller).
    my ($prog,$lno);
    my $i = 0;
    while (1) {
        (my $nsp,$prog,$lno) = (caller($i))[0,1,2] or last;
        last if $nsp !~ m/^File::Takeput(::.+)?$/n;
        $i++;
        };
    print STDERR $msg;
    print STDERR ' at '.$prog if defined $prog;
    print STDERR ' line '.$lno if defined $lno;
    print STDERR '.';
    };


my sub adverrh( $msg , $s ) {
# Advice and error handler.
    $msg .= $errh_msg if $errh_msg;
    $errh_msg = undef;
    advice($msg.'');
    $@ = $msg;
    return $s->{error}->() if defined $s->{error};
    return;
    };


my sub errh( $msg , $s = undef ) {
# Error handler.
    if (defined $s) { # For calls coming into Takeput.
        $msg .= $errh_msg if $errh_msg;
        $errh_msg = undef;
        $@ = $msg;
        return $s->{error}->() if defined $s->{error};
        }
    else { # For calls internal to Takeput.
        $errh_msg = $msg;
        };
    return;
    };


my sub fatal_error( $msg ) {
    advice($msg.'--compilation aborted');
    exit 1;
    };


my sub full_setting( $s ) {
# Check parameter values and provide a full setting.

    return {$default->%*} if not $s->%*;

    if (not exists $s->{create}) {
        $s->{create} = $default->{create};
        };

    if (exists $s->{error}) {
        if (defined $s->{error}) {
            return errh('"error" not a ref to a subroutine.')
              if ref $s->{error} ne 'CODE';
            };
        }
    else {
        $s->{error} = $default->{error};
        };

    if (not exists $s->{exclusive}) {
        $s->{exclusive} = $default->{exclusive};
        };

    if (not exists $s->{newline}) {
        $s->{newline} = $default->{newline};
        };

    if (exists $s->{patience}) {
        return errh('"patience" not defined.')
          if not defined $s->{patience};
        return errh('"patience" not numerical.')
          if $s->{patience} !~ m/^(\d*\.)?\d+$/n;
        return errh('"patience" negative.')
          if $s->{patience} < 0;
        }
    else {
        $s->{patience} = $default->{patience};
        };

    if (exists $s->{separator}) {
        return errh('"separator" an empty string.')
          if defined $s->{separator} and $s->{separator} eq '';
        }
    else {
        $s->{separator} = $default->{separator};
        };

    return $s;

    }; # sub full_setting

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #

sub import( @implist ) {
    my $mynsp = shift @implist;
    my $clnsp = caller;

    my sub amp( $s ) {
        return undef if not defined $s;
        return $s
          if $s =~ m/^(?:create|error|exclusive|newline|patience|separator)$/;
        return $s =~ s/^([^\$\@\%\&])/\&$1/r;
        };
    my %check = map {(amp($_),1)}
        qw(create error exclusive newline patience separator) ,
        @EXPORT ,
        @EXPORT_OK;
    my sub exportcheck( $s ) {
        return 1 if $check{$s};
        fatal_error('Takeput: "'.$s.'" not exported.');
        };

    my $cpar = {};
    @implist = @EXPORT if not @implist;
    while ($_ = amp shift @implist) {
        exportcheck($_);
        no strict "refs";
        if    ( m/^\$(.*)$/ ) { *{"${clnsp}::$1"} = \$$1; }
        elsif ( m/^\@(.*)$/ ) { *{"${clnsp}::$1"} = \@$1; }
        elsif ( m/^\%(.*)$/ ) { *{"${clnsp}::$1"} = \%$1; }
        elsif ( m/^\&(.*)$/ ) { *{"${clnsp}::$1"} = \&$1; }
        else {
            fatal_error('Takeput: No "'.$_.'" value.')
              if scalar @implist == 0;
            $cpar->{$_} = shift @implist;
            };
        use strict "refs";
        };

    my $s = full_setting($cpar)
      or fatal_error('Takeput: '.$errh_msg);
    $default = $s;

    }; # sub import

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #

1;

# --------------------------------------------------------------------------- #
# Private subroutines.

my sub canonical( $fname ) {
# Return a canonical filename.

    return abs_path($fname) if -f $fname;
    my $dname = dirname $fname;
    return undef if not -d $dname;
    return abs_path($dname).'/'.basename($fname);
    };


my sub open_file( $cname , $oflag , $lflag , $p ) {
# Open an implicit filehandle.

    return errh('Tried to open "'.$cname.'" twice.')
      if (exists $imfh{$cname});

    sysopen $imfh{$cname} , $cname , $oflag;
    if ( flock_take $imfh{$cname} , $lflag , $p ) {
        return 1;
        }
    else {
        close $imfh{$cname};
        delete $imfh{$cname};
        return errh('Not able to take lock for "'.$cname.'".');
        };
    1;};


my sub close_file( $cname ) {
# Close an implicit filehandle.

    return errh('No "'.$cname.'" found, could not close it.')
      if not exists $imfh{$cname};

    close( $imfh{$cname} )
      or return errh('Closing "'.$cname.'" failed. '.$@);
    delete $imfh{$cname};
    1;};


my sub read_file( $fh , $s ) {
# Read from filehandle, handling line endings as required.

    my $data;
    { # block
        local $/ = $s->{separator};
        $data->@* = readline($fh);
        };
    return [''] if scalar $data->@* == 0;

    if (defined $s->{newline} and defined $s->{separator}) {
        my $e0 = $s->{separator};
        my $e0n = length $s->{separator};
        my $e1 = $s->{newline};
        for (0 .. $data->$#* - 1) {
            substr($data->[$_],-$e0n) = $e1;
            };
        substr($data->[-1],-$e0n) = $e1
          if substr($data->[-1],-$e0n) eq $e0;
        };

    return $data;
    };


my sub print_file( $fh , $s , $data ) {
# Print to filehandle, changing line endings as required.

    if (defined $s->{newline} and defined $s->{separator}) {
        my $e0 = $s->{newline};
        my $e0n = length $s->{newline};
        my $e1 = $s->{separator};
        for (0 .. $data->$#* - 1) {
            print $fh substr($data->[$_],0,-$e0n) , $e1;
            };
        substr($data->[-1],0,-$e0n) = $e1
          if substr($data->[-1],0,-$e0n) eq $e0;
        print $fh $data->[-1];
        }
    else {
        print $fh $data->@*;
        };
    1;};

# --------------------------------------------------------------------------- #
# Exportable subroutines.

sub append( $fname , %set ) {
# Append @data to $fname.

    my $s = full_setting(\%set)
      or return adverrh('append: ',$default);
    my $oflag = $s->{create} ? O_CREAT : 0;
    my $cname = canonical $fname
      or return adverrh('append: No such file "'.$fname.'" possible.',$s);

    return sub( @data ) {
        return errh('append: "'.$cname.'" does not exist.',$s)
          if (not $s->{create}) and (not -f $cname);
        open_file($cname , O_WRONLY|$oflag , LOCK_EX , $s->{patience})
          or return errh('append: ',$s);
        seek $imfh{$cname} , 0 , 2;
        print_file($imfh{$cname} , $s , [@data]);
        close_file($cname)
          or return errh('append: ',$s);
        1;};
    };


sub grab( $fname , %set ) {
# Read content of $fname.
    return fgrab($fname,%set)->();
    };


sub pass( $fname , %set ) {
# Close filehandle for $fname without changing its content.
    return fpass($fname,%set)->();
    };


sub plunk( $fname , %set ) {
# Write @data to $fname.

    my $s = full_setting(\%set)
      or return adverrh('plunk: ',$default);
    my $oflag = $s->{create} ? O_CREAT : 0;
    my $cname = canonical $fname
      or return adverrh('plunk: No such file "'.$fname.'" possible.',$s);

    return sub( @data ) {
        return errh('plunk: "'.$cname.'" does not exist.',$s)
          if (not $s->{create}) and (not -f $cname);
        open_file( $cname , O_WRONLY|$oflag , LOCK_EX , $s->{patience})
          or return errh('plunk: ',$s);
        seek $imfh{$cname} , 0 , 0;
        truncate $imfh{$cname} , 0;
        print_file($imfh{$cname} , $s , [@data]);
        close_file($cname)
          or return errh('plunk: ',$s);
        1;};
    };


sub put( $fname , %set ) {
# Write content to $fname and close filehandle.

    my $s = full_setting(\%set)
      or return adverrh('put: ',$default);
    my $cname = canonical $fname
      or return adverrh('put: No such file "'.$fname.'" possible.',$s);

    return sub( @data ) {
        return errh('put: "'.$cname.'" does not exist.',$s)
          if not exists $imfh{$cname};
        my $kludge = $imfh{$cname};
        return errh('put: "'.$fname.'" no longer open.',$s)
          if not defined fileno($kludge);

        seek $imfh{$cname} , 0 , 0;
        truncate $imfh{$cname} , 0;
        print_file($imfh{$cname} , $s , [@data]);
        close_file($cname)
          or return errh('put: ',$s);
        1;};
    };


sub take( $fname , %set ) {
# Read content of $fname and keep filehandle open.
    return ftake($fname,%set)->();
    }; # sub take

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - #

sub fgrab( $fname , %set ) {
# Read content of $fname.

    my $s = full_setting(\%set)
      or return adverrh('grab: ',$default);
    my $lflag = $s->{exclusive} ? LOCK_EX : LOCK_SH;
    my $cname = canonical $fname
      or return adverrh('grab: No such file "'.$fname.'" possible.',$s);

    return sub {
        open_file $cname , O_RDONLY , $lflag , $s->{patience}
          or return errh('grab: ',$s);
    
        seek $imfh{$cname} , 0 , 0;
        my $data = read_file($imfh{$cname} , $s);
        close_file($cname)
          or return errh('grab: ',$s);
    
        return $data->@*;
        };
    };


sub fpass( $fname , %set ) {
# Close filehandle for $fname without changing its content.

    my $s = full_setting(\%set)
      or return adverrh('pass: ',$default);
    my $cname = canonical $fname
      or return adverrh('pass: No such file "'.$fname.'" possible.',$s);

    return sub {
        return errh('pass: "'.$fname.'" not taken.',$s)
          if not exists $imfh{$cname};
        return errh('pass: "'.$fname.'" not opened.',$s)
          if not defined fileno($imfh{$cname});
    
        close_file($cname)
          or return errh('pass: ',$s);
        };
    1;};


sub ftake( $fname , %set ) {
# Functional version of take.

    my $s = full_setting(\%set)
      or return adverrh('ftake: ',$default);
    my $oflag = $s->{create} ? O_CREAT : 0;
    my $cname = canonical $fname
      or return adverrh('ftake: No such file "'.$fname.'" possible.',$s);

    return sub {
        return errh('take: "'.$fname.'" does not exist.',$s)
          if (not $s->{create}) and (not -f $cname);
        open_file $cname , O_RDWR|$oflag , LOCK_EX , $s->{patience}
          or return errh('take: ',$s);
    
        seek $imfh{$cname} , 0 , 0;
        my $data = read_file($imfh{$cname} , $s);
        return $data->@*;
        };
    };


sub reset() {
# Change default settings to the original defaults.

    $default = {$urdefault->%*};
    1;};


sub set( %set ) {
# Change default settings.

    my $s = full_setting(\%set)
      or return adverrh('set: ',$default);

    $default = $s;
    1;};

# --------------------------------------------------------------------------- #

=pod

=encoding utf8

=head1 NAME

File::Takeput - Slurp style file IO with locking.

=head1 VERSION

0.10

=head1 SYNOPSIS

    use File::Takeput;

    # Lock some file and read its content.
    my @content1 = take('some_file_name.csv');

    # Read content of some other file.
    # Retry for up to 2.5 seconds if it is already locked.
    my @content2 = grab('some_other_file_name.log' , patience => 2.5);

    # Append some data to that other file.
    append('some_other_file_name.log')->(@some_data);

    # Read content of some third file as a single string.
    my ($content3) = grab('some_third_file_name.html' , separator => undef);

    # Write content back to the first file after editing it.
    # The locks will be released right afterwards.
    $content1[$_] =~ s/,/;/g for (0..$#content1);
    put('some_file_name.csv')->(@content1);

=head1 DESCRIPTION

Slurp style file IO with locking. The purpose of Takeput is to make it pleasant for you to script file IO. Slurp style is both user friendly and very effective, if you can have your files in memory.

The other major point of Takeput is locking. Takeput is careful to help your script be a good citizen in a busy filesystem. All its file operations respect and set flock locking. If your script misses a lock and does not release it, the lock will be released when your script terminates.

Encoding is often part of file IO operations, but Takeput keeps out of that. It reads and writes file content just as strings of bytes, in a sort of line-based binmode. Use some other module if you need decoding and encoding. For example:

    use File::Takeput;
    use Encode;

    my @article = map {decode('iso-8859-1',$_)} grab 'article.latin-1';

=head2 ERROR HANDLING

Takeput will die on compile-time errors, but not on runtime errors. In case of a runtime error it might issue a warning. But it will always write an error message in $@ and return an error value.

That said, you are able to change how runtime errors are handled, by using the L<"error" configuration parameter|/error>.

=head1 SUBROUTINES AND VARIABLES

Imported by default:
L<append|/append( $filename )-E<gt>( @data )>,
L<grab|/grab( $filename )>,
L<pass|/pass( $filename )>,
L<plunk|/plunk( $filename )-E<gt>( @data )>,
L<put|/put( $filename )-E<gt>( @data )>,
L<take|/take( $filename )>

Imported on demand:
L<fgrab|/fgrab( $filename )>,
L<fpass|/fpass( $filename )>,
L<ftake|/ftake( $filename )>,
L<reset|/reset>,
L<set|/set( %settings )>

=over

=item append( $filename )->( @data )

Appends @data to the $filename file.

=item grab( $filename )

Reads and returns the content of the $filename file. Will never change the content of $filename, or create the file.

Reading an empty file will return a list with one element, the empty string. If a false value is returned instead, it is because "grab" could not read the file.

=item pass( $filename )

Releases the lock on the $filename file. The content of the file will be the same as when the lock was taken (if everyone respects the locking). This is useful when a lock was taken with the "take" subroutine, but it later turned out that there was nothing to write to the file.

=item plunk( $filename )->( @data )

Overwrites the $filename file with @data.

=item put( $filename )->( @data )

Overwrites the taken $filename file, with @data, and releases the lock on it.

Setting the L<"create" configuration parameter|/create> on this call will not work. Set it on the "take" call instead.

=item take( $filename )

Sets a lock on the $filename file, reads and returns its content. A call to "take" should later on be followed by a call to "put" or "pass".

Reading an empty file will return a list with one element, the empty string. If a false value is returned instead, it is because "take" could not read the file.

=item fgrab( $filename )

A functional version of the "grab" subroutine.

=item fpass( $filename )

A functional version of the "pass" subroutine.

=item ftake( $filename )

A functional version of the "take" subroutine.

Note that "take"s twin, "put", also returns a function. With these you can separate the file operations from their definitions. As you can with filehandles. This is true for all the functional subroutines. Here is an example using "ftake" and "put", where they are sent as parameters.

    sub changecurr($r,$w,$x) {
        $w->( map {s/((\d*\.)?\d+)/$x*$1/ger} $r->() );
        };

    my $r = ftake('wednesday.csv' , patience => 5);
    my $w = put('wednesday.csv');
    my $rate = current_rate('GBP');
    changecurr($r,$w,$rate);

=item reset

Sets the default configuration parameters back to the Takeput defaults.

=item set( %settings )

Changes the default values to be %settings. Can be reset by calling "reset".

=back

=head1 CONFIGURATION

There are six configuration parameters.

=over

=item create

A scalar. If true the subroutines that have write intention, will create the file if it does not exist. If false, they will just fail if the file does not exist.

Be careful with this parameter. For example if a process renames the file while another process is waiting for the lock, that other process will open the file with the new name when it gets the lock. If it plunks, it is not to a file with the name it was called with, but to the file with this new name. Maybe not what is wanted...

The "create" parameter is ignored by "put". Use it on "take" instead, if you want this functionality.

=item error

A ref to a subroutine that is called if Takeput runs into a runtime error. It will be called without parameters. The $@ variable will be set just prior to the subroutine call, and the subroutines return value will be passed on back to your script. An example:

    use Logger::Syslog qw(warning);
    use File::Takeput error => sub {warning 'commit.pl: '.$@; die;};

    my @data = take('transaction.data' , patience => 10);
    do_stuff [@data];
    put('transaction.data')->(@data);

If you just need non-fatal warnings, here is a simple error handler you can use:

    use File::Takeput error => sub {print STDERR "$@\n"; undef;};

If the value of "error" is undef, Takeput will not make these calls.

=item exclusive

A scalar. If true Takeput will take an exclusive lock on read operations. If false it will just take a shared lock on them, as it normally does.

=item newline

A string that replaces the "separator" string at the end of each line when reading from a file. When writing to a file the replacement is the other way around. Then "separator" will replace "newline".

If either the "newline" value or the "separator" value is undef, no replacements will be done.

=item patience

The time in seconds that a call will wait for a lock to be released. The value can be fractional.

If "patience" is set to 0, there will be no waiting.

=item separator

The string defining the end of a line. It is used in read operations to split the data into lines. Note that the value is read as a bytestring. So take care if you use a special separator in combination with an unusual encoding.

Setting this parameter does not change the value of $/ or vice versa.

The "separator" value cannot de an empty string. If it is undef the data is seen as a single string.

=back

=head2 CONFIGURATION OPTIONS

You have a number of options for setting the configuration parameters.

=over

=item 1. In a file operation call, as optional named parameters.

=item 2. In a statement by calling "set" or "reset".

=item 3. Directly in the use statement of your script.

=item 4. Default configuration.

=back

If a parameter is set in more than one way, the most specific setting wins out. In the list above, the item with the lowest number wins out.

=head3 1. OPTIONAL NAMED PARAMETERS

All the file operation subroutines can take the configuration parameters as optional named parameters. That means that you can set them per call. The place to write them is after the filename parameter. Example:

    my @text = grab 'windows_file.txt' , separator => "\r\n" , newline => "\n";

=head3 2. SET AND RESET SUBROUTINES

The two subroutines "set" and "reset" is one way to set the default values for the configuration parameters. You use "set" to set custom values, and "reset" to set the values back to the Takeput defaults.

Think of it as assignment statements. If there are multiple calls, the last one is the one that is in effect.

=head3 3. USE STATEMENT

Another way to set the default values is in the use statement that imports Takeput. For example:

    use File::Takeput separator => "\n";

When you do it like this, the values are set at compile-time. Because of that, Takeput will die on any errors that these settings will give.

=head3 4. DEFAULT CONFIGURATION

The Takeput defaults are:

C<create>: undef (false)

C<error>: undef

C<exclusive>: undef (false)

C<newline>: undef

C<patience>: 0

C<separator>: $/ (at compile time)

=head1 DEPENDENCIES

Cwd

Fcntl

File::Basename

Time::HiRes

=head1 KNOWN ISSUES

No known issues.

=head1 TODO

Decide on empty string "separator". It ought to give a list of bytes, but readline gives an unintuitive list. It would be a mess with the line ending transformations.

An empty string will be an invalid value for now.

=head1 SEE ALSO

L<Encode|https://metacpan.org/pod/Encode>

L<File::Slurp|https://metacpan.org/pod/File::Slurp>

L<File::Slurper|https://metacpan.org/pod/File::Slurper>

=head1 LICENSE & COPYRIGHT

(c) 2023 Bjørn Hee

Licensed under the Apache License, version 2.0

https://www.apache.org/licenses/LICENSE-2.0.txt

=cut

__END__
