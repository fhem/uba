##############################################
# $Id: 60_uba.pm 00000 2018-06-03 $$$
#
#  60_uba.pm
#
#  2018 Markus Moises < vorname at nachname . de >
#  2020 Florian Asche <fhem@florian-asche.de>
#
#  This module provides air quality data from UBA stations
#
#  http://www.umweltbundesamt.de/daten/luftbelastung/aktuelle-luftdaten#/stations
#
##############################################################################
#
# define <name> uba <stationid>
#
##############################################################################

package FHEM::uba;

use strict;
use warnings;
use Time::Local;
use POSIX qw( strftime );
use Data::Dumper; #debugging
use Encode qw(encode_utf8);
use FHEM::Meta;
use GPUtils qw(GP_Import GP_Export);
use Time::Piece;


# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if ($@) {
    $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
          'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
          unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
                    $@ = undef;

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                }
            }
        }
    }
}


## Import der FHEM Funktionen
#-- Run before package compilation
BEGIN {

    # Import from main context
    GP_Import(
        qw(
          readingsSingleUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged
          readingsBeginUpdate
          readingsEndUpdate
          defs
          Log3
          CommandAttr
          attr
          readingFnAttributes
          AttrVal
          ReadingsVal
          FmtDateTime
          IsDisabled
          deviceEvents
          init_done
          HttpUtils_NonblockingGet
          gettimeofday
          InternalTimer
          RemoveInternalTimer
          ReplaceEventMap)
    );
}


#-- Export to main context with different name
GP_Export(
    qw(
      Initialize
      GetUpdate
      GetUpdateUBA
      )
);


# Components
my %components = (  
  '1' => 'PM10',  # Feinstaub
  '2' => 'CO',    # Kohlenstoffmonoxid
  '3' => 'O3',    # Ozon
  '4' => 'SO2',   # Schwefeldioxid
  '5' => 'NO2'    # Stickstoffdioxid
);


# Airquality
my %airquality = (  
  '0' => 'sehr gut',
  '1' => 'gut',
  '2' => 'mäßig',
  '3' => 'schlecht',
  '4' => 'sehr schlecht'
);


sub Initialize($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  $hash->{DefFn}        = "FHEM::uba::Define";
  $hash->{UndefFn}      = "FHEM::uba::Undefine";
  $hash->{GetFn}        = "FHEM::uba::Get";
  $hash->{AttrFn}       = "FHEM::uba::Attr";
  $hash->{NotifyFn}     = "FHEM::uba::Notify";
  $hash->{DbLog_splitFn}= "FHEM::uba::DbLog_splitFn";

  $hash->{AttrList}     = "disable:0,1 ".
                          "daysToImport ".
                          "showTimeReadings:0,1 ".
                          $readingFnAttributes;
}


sub Define($$$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  my ($found, $dummy);

  return "syntax: define <name> uba <uba_stationid>" if(int(@a) != 3 );
  my $name = $hash->{NAME};

  $hash->{helper}{STATION} = $a[2];
  $hash->{helper}{INTERVAL} = 3600;
  $hash->{NOTIFYDEV}      = "global,$name";

  CommandAttr(undef,$name . ' stateFormat Luftqualität: luftqualitaetsindex_name') if (AttrVal($name,'stateFormat','none') eq 'none');
  CommandAttr(undef,$name . ' daysToImport 30') if (AttrVal($name,'daysToImport','none') eq 'none');
  InternalTimer( gettimeofday() + 60, "uba_GetUpdate", $hash);
  readingsSingleUpdate($hash,'state','Initialized',1);

  return undef;
}


sub Undefine($$) {
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};
  RemoveInternalTimer($hash);
  return undef;
}

sub Notify($$) {

    my ($hash,$dev) = @_;
    my $name = $hash->{NAME};
    return if (IsDisabled($name));
    
    my $devname = $dev->{NAME};
    my $devtype = $dev->{TYPE};
    my $events = deviceEvents($dev,1);
    return if (!$events);


    GetUpdate($hash) if( grep /^INITIALIZED$/,@{$events}
                      or grep /^DELETEATTR.$name.disable$/,@{$events}
                      or grep /^DELETEATTR.$name.interval$/,@{$events}
                      or grep /^MODIFIED.$name$/,@{$events}
                      or (grep /^DEFINED.$name$/,@{$events} and $init_done) );
    return;
}


sub Get($@) {
  my ($hash, @a) = @_;
  my $command = $a[1];
  my $parameter = $a[2] if(defined($a[2]));
  my $name = $hash->{NAME};


  my $usage = "Unknown argument $command, choose one of data:noArg";

  return $usage if $command eq '?';

  if ( lc($command) eq 'data' ) {
      GetUpdate($hash);
  }

  return undef;
}


sub GetUpdate($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if(IsDisabled($name)) {
    readingsSingleUpdate($hash,'state','disabled',1);
    Log3 ($name, 2, "uba $name is disabled, data update cancelled.");
    RemoveInternalTimer($hash);
    return undef;
  }

  RemoveInternalTimer($hash);
  GetUpdateUBA($hash);  
  return undef;
}


sub GetUpdateUBA($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $station = $hash->{helper}{STATION};
  
  my ($now) = time;
  my $daysToImport = AttrVal($name, "showTimeReadings", "30");
  $hash->{helper}{initial_lastupdate} = int($now-(24*60*60*$daysToImport)-(strftime("%M",localtime($now))*60)-(strftime("%S",localtime($now))));

  my $lastupdate = ReadingsVal( $name, ".lastUpdate", $hash->{helper}{initial_lastupdate});
  $lastupdate = int($lastupdate-60); # remove 60 min. Making sure we get all data and dont miss anything.
  #$lastupdate = int($lastupdate-(24*60*60)); # For testing porpuse only
  Log3 $name, 4, ".lastUpdate: ($lastupdate)";

  my $lastupdate_day = localtime($lastupdate)->strftime('%F');  # lastupdate - day
  my $lastupdate_hour = localtime($lastupdate)->strftime('%H'); # lastupdate - hour

  # End Timestamp => Date/Time (+60 Minuten)
  my $enddate_timestamp = int($now+60); # add 60 min. Making sure we get all data and dont miss anything.
  my $enddate_day = localtime($enddate_timestamp)->strftime('%F');  # enddate - day
  my $enddate_hour = localtime($enddate_timestamp)->strftime('%H'); # enddate - hour

  my $url="https://www.umweltbundesamt.de/api/air_data/v2/airquality/json?date_from=".$lastupdate_day."&time_from=".$lastupdate_hour."&date_to=".$enddate_day."&time_to=".$enddate_hour."&station=".$station."&lang=de";

  HttpUtils_NonblockingGet({
    url         => $url,
    noshutdown  => 1,
    timeout     => 10,
    hash        => $hash,
    callback    => \&ParseUBA
  });

  Log3 ($name, 3, "Getting UBA data from URL: $url");
}


sub ParseUBA($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  if( $err )
  {
    Log3 $name, 1, "$name: URL error: ".$err;
    if(ReadingsVal($name,'state','error') ne "error"){
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+600), "uba_GetUpdate", $hash);
    } else {
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+3600), "uba_GetUpdate", $hash);
    }
    readingsSingleUpdate($hash,'state','error',1);
    return undef;
  }
  elsif (!defined($data) || length($data) == 0 || $data eq "") {
    Log3 $name, 2, "$name: no data retrieved from UBA";
    if(ReadingsVal($name,'state','error') ne "error"){
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+600), "uba_GetUpdate", $hash);
    } else {
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+3600), "uba_GetUpdate", $hash);
    }
    readingsSingleUpdate($hash,'state','error',1);
    return undef;
  }
  elsif( $data !~ m/^{.*}$/ ){
    Log3 $name, 2, "$name: JSON error for UBA (".$param->{type}." from ".$param->{range}.")";
    Log3 $name, 2, "$name: data for UBA: ".$data;

    if(ReadingsVal($name,'state','error') ne "error"){
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+600), "uba_GetUpdate", $hash);
    } else {
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+3600), "uba_GetUpdate", $hash);
    }
    readingsSingleUpdate($hash,'state','error',1);
    return undef;
  }
  
  #Log3 $name, 5, "$name: data for UBA: ".$data;
  WriteReadings($hash,$data,$param);
}


sub WriteReadings($@) {
  my ($hash,$data,$param)    = @_;
  my $name = $hash->{NAME};
  my $station = $hash->{helper}{STATION};
  
  # set program state/status
  readingsSingleUpdate($hash,'state','parsing',0);

  my $json = eval { JSON->new->utf8(0)->decode($data) };
  if($@)
  {
    Log3 $name, 2, "$name: JSON evaluation error for UBA (".$param->{type}." from ".$param->{range}.") ".$@;
 
    if(ReadingsVal($name,'state','error') ne "error"){
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+600), "uba_GetUpdate", $hash);
    } else {
      RemoveInternalTimer($hash, "uba_GetUpdate");
      InternalTimer(int(gettimeofday()+3600), "uba_GetUpdate", $hash);
    }
    readingsSingleUpdate($hash,'state','error',1);
    return undef;  
  }
  
  Log3 $name, 5, "JSON data: ".Dumper($json);

  #####################################################################################################
  # Array documentation:
  #|-> data
  ##|-> stationID
  ###|-> 0-XX = DATA
  ####|-> 0= DATE-TIME
  ####|-> 1= Luftqualitätsindex (0=sehr gut, 1=gut, 2=mäßig 3=schlecht 4=sehr schlecht )
  ####|-> 2= Daten Vollständig (0=JA, 1=NEIN)
  ####|-> 3-?= XXX
  #####|-> 0= components (1=PM10[Feinstaub], 2=CO[Kohlenstoffmonoxid], 3=O3[Ozon], 4=SO2[Schwefeldioxid], 5=NO2[Stickstoffdioxid])
  #####|-> 1= Stunden-Mittelwert
  #####|-> 2-?= unbekannt
  #####################################################################################################

  foreach my $datetimekey ( sort ( keys (%{$json->{"data"}->{$station}}))) {
    # Debug
    Log3 $name, 4, "-------------------------------";
    Log3 $name, 4, "x Array Key: ".$datetimekey;
    Log3 $name, 5, "-x Array Dump: ".Dumper($json->{"data"}->{$station}->{$datetimekey});
    Log3 $name, 4, "-1 Luftqualitaetsindex: ".$json->{"data"}->{$station}->{$datetimekey}[1];
    Log3 $name, 4, "-1 Luftqualitaetsindex_name: ".$airquality{$json->{"data"}->{$station}->{$datetimekey}[1]};
    Log3 $name, 4, "-2 Daten vollständig: ".$json->{"data"}->{$station}->{$datetimekey}[2];

    # Create Timestamp from Date and Time Measurement
    my $reading_datetime = $json->{"data"}->{$station}->{$datetimekey}[0]." +0100";
    Log3 $name, 4, "-0 DateTime: ".$reading_datetime; # 2020-01-21 14:00:00
    
    # WORKAROUND: Es gibt kein 24:00:00 Uhr sondern nur 00:00:00. Das wird hiermit korrigiert!
    my $measured_datetime_timestamp;
    if($reading_datetime =~ m/24:00:00/){
      Log3 $name, 4, "-0 Applying Date/Time fix";
      $reading_datetime =~ s/ 24:/ 00:/;
      Log3 $name, 4, "-0 DateTime (after fix): ".$reading_datetime;
      my $tp = Time::Piece->strptime($reading_datetime, "%Y-%m-%d %H:%M:%S %z");
      $measured_datetime_timestamp = int($tp->epoch+(23*60*60));
      Log3 $name, 4, "-0 DateTime (after fix) (from timestamp): ".localtime($measured_datetime_timestamp)->strftime("%Y-%m-%d %H:%M:%S");
    } else {
      my $tp = Time::Piece->strptime($reading_datetime, "%Y-%m-%d %H:%M:%S %z");
      $measured_datetime_timestamp = $tp->epoch;
    }

    # Debug
    Log3 $name, 4, "-0 DateTime (timestamp): ".$measured_datetime_timestamp;

    # Wann wurde das letzte Update an Daten eingespielt?
    my $lastupdate_timestamp = ReadingsVal( $name, ".lastUpdate", $hash->{helper}{initial_lastupdate});
    Log3 $name, 4, "-0 LastUpdate (timestamp): ".$lastupdate_timestamp;

    # Skip duplicate
    if($measured_datetime_timestamp <= $lastupdate_timestamp) {
      Log3 $name, 4, "Skip this reading. It should be already in database.";
      next;
    }

    # Start data update
    readingsBeginUpdate($hash);

    # Set specific reading time from dataset
    $hash->{CHANGETIME}[0] = FmtDateTime($measured_datetime_timestamp);
    $hash->{".updateTimestamp"} = FmtDateTime($measured_datetime_timestamp);

    # Save Luftqualitätsindex
    readingsBulkUpdateIfChanged($hash,"luftqualitaetsindex",$json->{"data"}->{$station}->{$datetimekey}[1]);
    # Save Luftqualitätsindex_name
    readingsBulkUpdateIfChanged($hash,"luftqualitaetsindex_name",$airquality{$json->{"data"}->{$station}->{$datetimekey}[1]});
  
    # Search and work on each specific available dataset
    my $dataset_size = @{$json->{"data"}->{$station}->{$datetimekey}};
    Log3 $name, 5, "x dataset_size: $dataset_size";
    for ( my $i = 3; $i < $dataset_size; $i++ ) {
      Log3 $name, 4, "-$i 0 component ID: ".$i;
      Log3 $name, 4, "--$i 0 component: ".$json->{"data"}->{$station}->{$datetimekey}[$i][0];
      Log3 $name, 4, "--$i 0 component_name: ".$components{$json->{"data"}->{$station}->{$datetimekey}[$i][0]};
      Log3 $name, 4, "--$i 1 data: ".$json->{"data"}->{$station}->{$datetimekey}[$i][1];

      # Save Datasets
      readingsBulkUpdateIfChanged($hash, $components{$json->{"data"}->{$station}->{$datetimekey}[$i][0]}, $json->{"data"}->{$station}->{$datetimekey}[$i][1]);
    }

    # Updaten der .lastUpdate
    if( $measured_datetime_timestamp > $lastupdate_timestamp ){
      # Er soll nur den höchsten Wert schreiben
      Log3 $name, 4, "Writing new lastUpdate ($measured_datetime_timestamp)";
      readingsBulkUpdateIfChanged($hash,".lastUpdate",$measured_datetime_timestamp, 0);
      readingsBulkUpdateIfChanged($hash,"lastUpdate",FmtDateTime($measured_datetime_timestamp), 0) if(AttrVal($name, "showTimeReadings", 0) eq 1);
    }

    # End data update
    readingsEndUpdate($hash, 1);
  }
  
  # Set timer
  my $nextupdate = gettimeofday()+$hash->{helper}{INTERVAL};
  RemoveInternalTimer($hash, "uba_GetUpdate");
  InternalTimer($nextupdate, "uba_GetUpdate", $hash);

  # set program state/status
  readingsSingleUpdate($hash,'state','done',0);
  readingsSingleUpdate($hash,'Quellenangabe','Umweltbundesamt mit Daten der Messnetze der Länder und des Bundes',0);
  Log3 $name, 3, "UBA: Done loading all data";

  return undef;
}


sub Attr(@)
{
  my ($cmd, $device, $attribName, $attribVal) = @_;
  my $hash = $defs{$device};

  $attribVal = "" if (!defined($attribVal));
  
  return undef;
}


sub DbLog_splitFn($) {
  my ($event) = @_;
  my ($reading, $value, $unit) = "";

  my @parts = split(/ /,$event,3);
  $reading = $parts[0];
  $reading =~ tr/://d;
  $value = $parts[1];
  $unit = "µg/m³";

  Log3 "dbsplit", 5, "uba dbsplit: ".$event."\n$reading: $value $unit";

  return ($reading, $value, $unit);
}

##########################

1;

=pod
=item device
=item summary Air quality data for Germany, provided by UBA
=begin html

<a name="uba"></a>
<h3>uba</h3>
<ul>
  This modul provides air quality data for Germany, measured by UBA stations. 24:00:00 will be translated to 00:00:00 next day.<br/>
  <br/><br/>
  Disclaimer:<br/>
  Users are responsible for compliance with the respective terms of service, data protection and copyright laws.<br/><br/>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; uba &lt;uba_stationid&gt;</code>
    <br>
    Example: <code>define airdata uba 1290</code>
    <br>&nbsp;
    <li><code>uba_stationid</code>
      <br>
      UBA Station ID, see <a href="https://www.umweltbundesamt.de/daten/luft/luftdaten/luftqualitaet">https://www.umweltbundesamt.de/daten/luft/luftdaten/luftqualitaet</a>
      <br>If you go to CSV Export, you can see the Station Number in the URL.
    </li><br>
  </ul>
  <br>
  <b>Attributes</b>
  <ul>
    <li><code>disable</code>
      <br>
      Disables the module
    </li><br>
    <li><code>daysToImport</code>
      <br>
      Set how many days back (from now) you want to import. Default is 30. But this should only apply if the .lastUpdate is also older than 30 days.
    </li><br>
    <li><code>showTimeReadings</code>
      <br>
      Create visible readings for last update times
    </li><br>
  </ul>
  <br>
  <b>Get</b>
   <ul>
      <li><code>data</code>
      <br>
      Manually trigger data update
      </li><br>
  </ul>
  <br>
  <b>Readings</b>
    <ul>
      <li><code>luftqualitaetsindex</code>
      <br>
      Luftqualitaetsindex by Number. 0 is best, 4 is worst<br/>
      </li><br>
      <li><code>luftqualitaetsindex_name</code>
      <br>
      Luftqualitaetsindex by german scale<br/>
      </li><br>
      <li><code>CO</code>
      <br>
      CO data (Kohlenstoffmonoxid) in µg/m³, 8h median value<br/>
      </li><br>
      <li><code>NO2</code>
      <br>
      NO2 data (Stickstoffdioxid) in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>O3</code>
      <br>
      O3 data (Ozon) in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>PM10</code>
      <br>
      PM10 data (Feinstaub) in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>SO2</code>
      <br>
      SO2 data (Schwefeldioxid) in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>lastUpdateXX</code>
      <br>
      Last update time for pollutant XX (only if enabled through showTimeReadings)<br/>
      </li><br>
    </ul>
</ul>

=end html

=for :application/json;q=META.json 60_uba.pm
{
  "abstract": "Air quality data for Germany, provided by UBA",
  "x_lang": {
    "de": {
      "abstract": "Daten zur Luftqualität in Deutschland, geliefert vom UBA"
    }
  },
  "keywords": [
    "fhem-mod-device",
    "fhem-3rd-part",
    "Air quality",
    "UBA"
  ],
  "release_status": "unstable",
  "license": "GPL_2",
  "author": [
    "Florian Asche <fhemDevelopment@florian-asche.de>"
  ],
  "x_fhem_maintainer": [
    "Florian_GT"
  ],
  "x_fhem_maintainer_github": [
    "florian-asche"
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "FHEM": 5.00918799,
        "perl": 5.016, 
        "Meta": 0,
        "JSON": 0,
        "HttpUtils": 0,
        "Encode": 0
      },
      "recommends": {
      },
      "suggests": {
      }
    }
  }
}
=end :application/json;q=META.json

=cut
