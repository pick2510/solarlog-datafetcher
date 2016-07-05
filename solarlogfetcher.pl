use strict;
use warnings;
use Digest::MD5;
use Getopt::Std;
use Config::General;
use HTTP::Tiny;
use FileHandle;
use Time::Piece;
use Time::Seconds;
use utf8;
use Term::ProgressBar::Simple;
use Data::Dumper;
use open ':encoding(utf8)';
use 5.16.0;

my $debug  = 0;
my %opts   = ();
my %config = ();
my @content;    # Merged content
my @invlist = ();
my $invcount;
my $stringcount;
my $startdate;
my $enddate;
my $mode;
my $pwd;
my $sn;
my $pvname;
my %invdata;
my $base_file = "base_vars.js";
my $base_vars_url =
    "http://clevergie.solarlog-web.ch/api?access=iphone&file=%s&sn=%s&pwd=%s";

# Example Config

my %exampleconfig = (
    Mode         => 1,
    Startdate    => ( Time::Piece->new - ONE_MONTH * 3 )->dmy,
    Enddate      => ( Time::Piece->new - ONE_MONTH )->dmy,
    Serialnumber => "12342344234",
    Password     => "sdjfsdfk"
);

# Get Data From Solarlog Webserver

sub getData {
    say "==============================================================";
    say "Fetching Data from " . $startdate->dmy . " until " . $enddate->dmy;
    say "==============================================================";
    my $nowdate  = $startdate;
    my $daycount = int( ( $enddate - $nowdate ) / 86400 );
    my $progress = Term::ProgressBar::Simple->new($daycount);
    while ( $nowdate < $enddate ) {
        my $file = "min" . $nowdate->strftime("%y%m%d") . ".js";
        my $url = sprintf( $base_vars_url, $file, $sn, calcHash($pwd) );
        say $url if $debug == 1;
        my $response = HTTP::Tiny->new->get($url);
        my $str      = $response->{content};
        utf8::encode($str);
        $str =~ s/m\[mi\+\+\]\=\"|"//g;
        my @partlist = split( /\n/, $str );
        push( @content, @partlist );
        $nowdate += ONE_DAY;
        $progress++;
    }
    @content = reverse @content;
}

sub generateCSVHeaderForEachInv {
    say "==============================================================";
    say "Generate CSV header for each Inverter";
    say "==============================================================";
    foreach my $i ( 0 .. $invcount - 1 ) {
        my $inv          = $i + 1;
        my $headerstring = "Date/Time;PAC Inv $inv [W];";
        foreach my $string ( 1 .. $invdata{$i}{Count} ) {
            $headerstring .= "PDC Inv $inv String $string [W];";
        }
        $headerstring .= "Tagesertrag Inv $inv [Wh];";
        foreach my $string ( 1 .. $invdata{$i}{Count} ) {
            $headerstring .= "UDC Inv $inv String $string [V]";
            $headerstring .= ";" if $string < ( $invdata{$i}{Count} );
        }
        $invdata{$i}{Header} = $headerstring . "\n";
        say $invdata{$i}{Header} if $debug == 1;

    }

}

sub parseBaseVars {
    my $baseurl = sprintf( $base_vars_url, $base_file, $sn, calcHash($pwd) );
    say $baseurl if $debug == 1;
    my $response = HTTP::Tiny->new->get($baseurl);
    if ( $debug == 1 ) {
        while ( my ( $k, $v ) = each %{ $response->{headers} } ) {
            for ( ref $v eq 'ARRAY' ? @$v : $v ) {
                print "$k: $_\n";
            }
        }
    }
    my $str = $response->{content};
    utf8::encode($str);
    say $str if $debug == 1;
    my @baselist = split( /\n/, $str );
    $pvname = join( " ", grep( /HPTitel/, @baselist ) );
    $pvname = $& if ( $pvname =~ /\".*\"/ ) or die "ERROR: No PVName found";
    say "==============================================================";
    say "Working on: $pvname ";
    say "==============================================================";
    @invlist = grep( /^WRInfo/, @baselist );
    my $invcountline =
        join( "", grep( /var\sWRInfo=new\sArray/, @baselist ) );
    $invcount = $&
        if ( $invcountline =~ /\d+/ )
        or die "ERROR, No Inverter(s) found!";
    say "==============================================================";
    say "Found $invcount Inverter(s)";
    say "==============================================================";
}

sub parseInverters {
    say "==============================================================";
    say "Parsing Inverter(s)";
    say "==============================================================";
    my $flatlist = join( " ", @invlist );
    foreach my $i ( 0 .. $invcount - 1 ) {
        say "Parsing Inverter ", $i + 1;
        my $typestring = qr/(?<=WRInfo\[$i\]\=new\sArray\(\")[\w\s-]*/;
        my $stringnamestring =
            qr/(?<=WRInfo\[$i\]\[6\]\=new\sArray\(\")[\w\s,\"]*/;
        my $stringcountstring =
            qr/(?<=WRInfo\[$i\]\[7\]\=new\sArray\()[\w\s,]*/;
        $invdata{$i}{Name} = $& if ( $flatlist =~ $typestring );
        my $stringnames;
        $stringnames = $& if ( $flatlist =~ $stringnamestring );
        $stringnames =~ s/\"//g;
        $invdata{$i}{Stringnames} =
            [ split( /\,/, $stringnames ) ];
        $invdata{$i}{Count} = split( /\,/, $& )
            if ( $flatlist =~ $stringcountstring );
        $stringcount += $invdata{$i}{Count};    #
    }
    print Dumper \%invdata if $debug == 1;
    say "==============================================================";
    say "Got $stringcount String(s) at $invcount Inverter(s)";
    say "==============================================================";

}

sub splitContent {
    my $warnflag = 0;
    foreach my $i ( 0 .. $invcount - 1 ) {
        $invdata{$i}{Data} = [];
    }
    foreach my $line (@content) {
        my @listofvalues;
        @listofvalues = split( /\|/, $line );
        foreach my $i ( 0 .. $invcount - 1 ) {
            my $csvline;
            if ( defined( $listofvalues[ $i + 1 ] ) ) {
                $csvline =
                    $listofvalues[0] . ";" . $listofvalues[ $i + 1 ] . "\n";
            }
            elsif ( $warnflag == 0 ) {
                warn "Data of Inverter ", $i + 1,
                    " is not defined. Maybe no data?";
                $csvline = $listofvalues[0] . ";undef;" . "\n";
                $warnflag++;
            }
            else {
                $csvline = $listofvalues[0] . ";undef;" . "\n";
            }
            push @{ $invdata{$i}{Data} }, $csvline;
        }
    }
}

sub writeCSV {
    $pvname =~ s/[^A-Za-z0-9.-]//g;
    foreach my $i ( 0 .. $invcount - 1 ) {
        my $filename = $pvname . "_Inverter" . ( $i + 1 ) . ".csv";
        utf8::encode($filename);
        my $fh = FileHandle->new( $filename, "w" );
        $fh->print( $invdata{$i}{Header} );
        $fh->print( @{ $invdata{$i}{Data} } );
        $fh->close;
    }
}

sub checkConfig {
    if ( !-e "solarlogfetcher.conf" ) {
        return 0;
    }
    elsif ( -r "solarlogfetcher.conf" && -w "solarlogfetcher.conf" ) {
        return 1;
    }
    else {
        say "==============================================================";
        say "Permission Problem, wrong user? exiting...";
        say "==============================================================";
        exit;
    }
}

sub parseDates {
    $startdate = Time::Piece->strptime( $startdate, "%d-%m-%Y" );
    $enddate   = Time::Piece->strptime( $enddate,   "%d-%m-%Y" );
}

sub calcHash {
    my $pw  = shift;
    my $md5 = Digest::MD5->new;
    $md5->add($pw);
    my $digest = $md5->hexdigest;
    return $digest;
}

sub main {
    getopts( 'x', \%opts );
    if ( !$opts{x} ) {
        say "=============================================================";
        say "Welcome to the Solarlog Data Fetcher.";
        say "App Access must be activated to work";
        say "Please configure settings in the Configfile";
        say qw{"solarlogfetcher.conf"} . " in your homedir";
        say "Execute Solarlog Data Fetcher by invoking -x option";
        say "==============================================================";
        exit;
    }
    say "==============================================================";
    say "Try to open config";
    say "==============================================================";
    if ( checkConfig == 0 ) {
        say "==============================================================";
        say "Configfile doesn't exists";
        say "Writing example config......";
        say "==============================================================";
        my $conf = Config::General->new(
            -ConfigHash => \%exampleconfig,
            -SaveSorted => 1
        );
        $conf->save_file("solarlogfetcher.conf");
        exit;
    }
    say "==============================================================";
    say "Config File found, try to read..";
    say "==============================================================";
    my $conf = Config::General->new(
        -ConfigFile => "solarlogfetcher.conf",
        -SaveSorted => 1
    );
    %config    = $conf->getall;
    $startdate = $config{Startdate};
    $enddate   = $config{Enddate};
    $mode      = $config{Mode};
    $sn        = $config{Serialnumber};
    $pwd       = $config{Password};
    parseDates;
    say "==============================================================";
    say "Ok, I try to read data from "
        . $startdate->dmy
        . " until "
        . $enddate->dmy;
    say "==============================================================";
    parseBaseVars;
    parseInverters;
    generateCSVHeaderForEachInv;
    getData;
    splitContent;
    writeCSV;
}

main();
