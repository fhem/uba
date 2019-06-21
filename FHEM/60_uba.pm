##############################################
# $Id: 60_uba.pm 00000 2018-06-03 $$$
#
#  60_uba.pm
#
#  2018 Markus Moises < vorname at nachname . de >
#  2019 Florian Asche <fhem@florian-asche.de>
#
#  This module provides air quality data from UBA stations
#  and ambient dose rate data from BfS stations
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

my %station_names = (  
  'DEBB007' => 'Elsterwerda',
  'DEBB021' => 'Potsdam-Zentrum',
  'DEBB029' => 'Schwedt (Oder)',
  'DEBB032' => 'Eisenhüttenstadt',
  'DEBB044' => 'Cottbus, Bahnhofstr.',
  'DEBB045' => 'Frankfurt (Oder), Leipziger Str.',
  'DEBB048' => 'Neuruppin',
  'DEBB049' => 'Brandenburg, Neuendorfer Str.',
  'DEBB053' => 'Hasenholz',
  'DEBB054' => 'Potsdam Zeppelinstr.',
  'DEBB055' => 'Brandenburg a.d. Havel',
  'DEBB060' => 'Eberswalde Breite Straße',
  'DEBB063' => 'Wittenberge',
  'DEBB064' => 'Cottbus',
  'DEBB065' => 'Lütte (Belzig)',
  'DEBB066' => 'Spreewald',
  'DEBB067' => 'Nauen',
  'DEBB068' => 'Bernau, Lohmühlenstr.',
  'DEBB073' => 'Potsdam, Großbeerenstr.',
  'DEBB075' => 'Potsdam, Groß Glienicke',
  'DEBB083' => 'Spremberg',
  'DEBB086' => 'Blankenfelde-Mahlow',
  'DEBB087' => 'Cottbus, W.-Külz-Str.',
  'DEBB092' => 'Frankfurt (Oder)',
  'DEBB099' => 'Herzfelde, Hauptstr.',
  'DEBE010' => 'B Wedding-Amrumer Str.',
  'DEBE018' => 'B Schöneberg-Belziger Straße',
  'DEBE027' => 'B Marienfelde-Schichauweg',
  'DEBE032' => 'B Grunewald (3.5 m)',
  'DEBE034' => 'B Neukölln-Nansenstraße',
  'DEBE051' => 'B Buch',
  'DEBE056' => 'B Friedrichshagen',
  'DEBE061' => 'B Steglitz-Schildhornstr.',
  'DEBE062' => 'B Frohnau, Funkturm (3.5 m)',
  'DEBE063' => 'B Neukölln-Silbersteinstr.',
  'DEBE064' => 'B Neukölln-Karl-Marx-Str. 76',
  'DEBE065' => 'B Friedrichshain-Frankfurter Allee',
  'DEBE066' => 'B Karlshorst-Rheingoldstr./Königswinterstr.',
  'DEBE067' => 'B Hardenbergplatz',
  'DEBE068' => 'B Mitte, Brückenstraße',
  'DEBE069' => 'B Mariendorf, Mariendorfer Damm',
  'DEBW004' => 'Eggenstein',
  'DEBW005' => 'Mannheim-Nord',
  'DEBW009' => 'Heidelberg',
  'DEBW010' => 'Wiesloch',
  'DEBW013' => 'Stuttgart Bad Cannstatt',
  'DEBW015' => 'Heilbronn',
  'DEBW019' => 'Ulm',
  'DEBW022' => 'Kehl',
  'DEBW023' => 'Weil am Rhein',
  'DEBW024' => 'Ludwigsburg',
  'DEBW027' => 'Reutlingen',
  'DEBW029' => 'Aalen',
  'DEBW031' => 'Schwarzwald-Süd',
  'DEBW033' => 'Pforzheim',
  'DEBW038' => 'Friedrichshafen',
  'DEBW039' => 'Villingen-Schwenningen',
  'DEBW042' => 'Bernhausen',
  'DEBW046' => 'Biberach',
  'DEBW052' => 'Konstanz',
  'DEBW056' => 'Schwäbisch_Hall',
  'DEBW059' => 'Tauberbischofsheim',
  'DEBW073' => 'Neuenburg',
  'DEBW076' => 'Baden-Baden',
  'DEBW080' => 'Karlsruhe_Reinhold-Frank-Strasse',
  'DEBW081' => 'Karlsruhe-Nordwest',
  'DEBW084' => 'Freiburg',
  'DEBW087' => 'Schwäbische_Alb',
  'DEBW098' => 'Mannheim_Friedrichsring',
  'DEBW099' => 'Stuttgart_Arnulf-Klett-Platz',
  'DEBW107' => 'Tübingen',
  'DEBW112' => 'Gaertringen',
  'DEBW116' => 'Stuttgart Hohenheimer Straße (S)',
  'DEBW117' => 'Ludwigsburg Friedrichstraße (S)',
  'DEBW118' => 'Stuttgart Am Neckartor (S)',
  'DEBW120' => 'Leonberg Grabenstraße (S)',
  'DEBW122' => 'Freiburg Schwarzwaldstraße (V)',
  'DEBW125' => 'Pfinztal Karlsruher Straße (S)',
  'DEBW136' => 'Tübingen Mühlstraße (S)',
  'DEBW137' => 'Tübingen-Unterjesingen Jesinger Hauptstraße (S)',
  'DEBW142' => 'Markgröningen Grabenstraße (S)',
  'DEBW147' => 'Reutlingen Lederstraße Ost (S)',
  'DEBW152' => 'Heilbronn Weinsberger Straße Ost (S)',
  'DEBW156' => 'Schramberg Oberndorfer Straße',
  'DEBW219' => 'Backnang Eugen-Adolff-Straße',
  'DEBW220' => 'Esslingen am Neckar Grabbrunnenstraße',
  'DEBW221' => 'Konstanz Theodor-Heuss-Straße',
  'DEBW222' => 'Kuchen Hauptstraße',
  'DEBW223' => 'Leinfelden-Echterdingen Echterdingen Hauptstraße',
  'DEBY001' => 'Ansbach/Residenzstraße',
  'DEBY002' => 'Arzberg/Egerstraße',
  'DEBY004' => 'Kleinwallstadt/Hofstetter Straße',
  'DEBY005' => 'Aschaffenburg/Bussardweg',
  'DEBY006' => 'Augsburg/Königsplatz',
  'DEBY007' => 'Augsburg/Bourges-Platz',
  'DEBY009' => 'Bamberg/Löwenbrücke',
  'DEBY012' => 'Burghausen/Marktler Straße',
  'DEBY013' => 'Mehring/Sportplatz',
  'DEBY014' => 'Coburg/Lossaustraße',
  'DEBY020' => 'Hof/LfU',
  'DEBY021' => 'Ingolstadt/Rechbergstraße',
  'DEBY026' => 'Vohburg a.d. Donau/Alter Wöhrer Weg',
  'DEBY028' => 'Kelheim/Regensburger Straße',
  'DEBY030' => 'Saal a.d. Donau/Regensburger Straße',
  'DEBY031' => 'Kempten (Allgäu)/Westendstraße',
  'DEBY032' => 'Kulmbach/Konrad-Adenauer-Straße',
  'DEBY033' => 'Landshut/Podewilsstraße',
  'DEBY035' => 'Lindau (Bodensee)/Friedrichshafener Straße',
  'DEBY037' => 'München/Stachus',
  'DEBY039' => 'München/Lothstraße',
  'DEBY047' => 'Naila/Selbitzer Berg',
  'DEBY049' => 'Neustadt a.d. Donau/Eining',
  'DEBY052' => 'Neu-Ulm/Gabelsbergerstraße',
  'DEBY053' => 'Nürnberg/Bahnhof',
  'DEBY056' => 'Fürth/Theresienstraße',
  'DEBY058' => 'Nürnberg/Muggenhof',
  'DEBY062' => 'Regen/Bodenmaiser Straße',
  'DEBY063' => 'Regensburg/Rathaus',
  'DEBY067' => 'Schwandorf/Wackersdorfer Straße',
  'DEBY068' => 'Schweinfurt/Obertor',
  'DEBY072' => 'Tiefenbach/Altenschneeberg',
  'DEBY075' => 'Weiden i.d.OPf./Nikolaistraße',
  'DEBY077' => 'Würzburg/Kopfklinik',
  'DEBY079' => 'Bad Reichenhall/Nonn',
  'DEBY088' => 'Trostberg/Schwimmbadstraße',
  'DEBY089' => 'München/Johanneskirchen',
  'DEBY093' => 'Sulzbach-Rosenberg/Lohe',
  'DEBY099' => 'Augsburg/LfU',
  'DEBY109' => 'Andechs/Rothenfeld',
  'DEBY110' => 'Augsburg/Karlstraße',
  'DEBY111' => 'Bayreuth/Hohenzollernring',
  'DEBY113' => 'Erlangen/Kraepelinstraße',
  'DEBY115' => 'München/Landshuter Allee',
  'DEBY118' => 'Passau/Stelzhamerstraße',
  'DEBY119' => 'Würzburg/Stadtring Süd',
  'DEBY120' => 'Nürnberg/Von-der-Tann-Straße',
  'DEBY121' => 'Oberaudorf/Inntal-Autobahn',
  'DEBY122' => 'Bad Hindelang/Oberjoch',
  'DEBY124' => 'Burgbernheim/Grüne Au',
  'DEBY187' => 'Oettingen/Goethestraße',
  'DEBY188' => 'Schwabach/Angerstraße',
  'DEBY189' => 'München/Allach',
  'DEBY196' => 'Garmisch-Partenkirchen/Wasserwerk',
  'DEHB001' => 'Bremen-Mitte',
  'DEHB002' => 'Bremen-Ost',
  'DEHB004' => 'Bremen-Nord',
  'DEHB005' => 'Bremerhaven',
  'DEHB006' => 'Bremen Verkehr 1',
  'DEHB011' => 'Cherbourger Straße',
  'DEHB012' => 'Bremen-Oslebshausen',
  'DEHB013' => 'Bremen-Hasenbüren',
  'DEHE001' => 'Darmstadt',
  'DEHE005' => 'Frankfurt-Höchst',
  'DEHE008' => 'Frankfurt-Ost',
  'DEHE011' => 'Hanau',
  'DEHE013' => 'Kassel-Mitte',
  'DEHE018' => 'Raunheim',
  'DEHE020' => 'Wetzlar',
  'DEHE022' => 'Wiesbaden-Süd',
  'DEHE024' => 'Witzenhausen/Wald',
  'DEHE026' => 'Spessart',
  'DEHE028' => 'Fürth/Odenwald',
  'DEHE030' => 'Marburg',
  'DEHE032' => 'Bebra',
  'DEHE037' => 'Wiesbaden-Ringkirche',
  'DEHE039' => 'Burg Herzberg (Grebenau)',
  'DEHE040' => 'Darmstadt-Hügelstraße',
  'DEHE041' => 'Frankfurt-Friedb.Ldstr.',
  'DEHE042' => 'Linden/Leihgestern',
  'DEHE043' => 'Riedstadt',
  'DEHE044' => 'Limburg',
  'DEHE045' => 'Michelstadt',
  'DEHE046' => 'Bad Arolsen',
  'DEHE049' => 'Kassel-Fünffenster-Str.',
  'DEHE050' => 'Zierenberg',
  'DEHE051' => 'Wasserkuppe',
  'DEHE052' => 'Kleiner Feldberg',
  'DEHE058' => 'Fulda-Mitte',
  'DEHE059' => 'Fulda-Petersberger Str.',
  'DEHE060' => 'Kellerwald',
  'DEHE061' => 'Gießen-Westanlage',
  'DEHE062' => 'Marburg-Univers.Straße',
  'DEHE063' => 'Heppenheim-Lehrstraße',
  'DEHE095' => 'DHA80 Wetzlar-Köhlersgarten',
  'DEHE112' => 'Wiesbaden-Schiersteiner Str.',
  'DEHE116' => 'Offenbach-Untere Grenzstraße',
  'DEHE131' => 'Limburg-Schiede',
  'DEHE134' => 'Fulda-Zentral',
  'DEHH008' => 'Hamburg Sternschanze',
  'DEHH015' => 'Hamburg Veddel',
  'DEHH016' => 'Hamburg Billbrook',
  'DEHH021' => 'Hamburg Tatenberg',
  'DEHH026' => 'Hamburg Stresemannstraße',
  'DEHH033' => 'Hamburg Flughafen Nord',
  'DEHH047' => 'Hamburg Bramfeld',
  'DEHH049' => 'Hamburg Blankenese-Baursberg',
  'DEHH050' => 'Hamburg Neugraben',
  'DEHH059' => 'Hamburg Wilhelmsburg',
  'DEHH064' => 'Hamburg Kieler Straße',
  'DEHH068' => 'Hamburg Habichtstraße',
  'DEHH070' => 'Hamburg Max-Brauer-Allee II (Straße)',
  'DEHH072' => 'Hamburg Finkenwerder West',
  'DEHH073' => 'Hamburg Finkenwerder Airbus',
  'DEHH074' => 'Hamburg Billstedt',
  'DEHH079' => 'Hamburg Altona Elbhang',
  'DEHH081' => 'Hamburg Hafen',
  'DEMV003' => 'Neubrandenburg',
  'DEMV004' => 'Gülzow',
  'DEMV007' => 'Rostock-Stuthof',
  'DEMV012' => 'Löcknitz',
  'DEMV017' => 'Göhlen',
  'DEMV019' => 'Güstrow',
  'DEMV020' => 'Rostock Am Strande',
  'DEMV021' => 'Rostock-Warnemünde',
  'DEMV022' => 'Rostock-Holbeinplatz',
  'DEMV023' => 'Schwerin-Obotritenring',
  'DEMV024' => 'Leizen',
  'DEMV025' => 'Stralsund-Knieperdamm',
  'DEMV026' => 'Garz',
  'DEMV031' => 'Rostock-Hohe Düne',
  'DENI011' => 'Braunschweig',
  'DENI016' => 'Oker/Harlingerode',
  'DENI020' => 'Wolfsburg',
  'DENI028' => 'Eichsfeld',
  'DENI029' => 'Ostfriesland',
  'DENI031' => 'Jadebusen',
  'DENI038' => 'Osnabrück',
  'DENI041' => 'Weserbergland',
  'DENI042' => 'Göttingen',
  'DENI043' => 'Emsland',
  'DENI048' => 'Hannover Verkehr',
  'DENI051' => 'Wurmberg',
  'DENI052' => 'Allertal',
  'DENI053' => 'Südoldenburg',
  'DENI054' => 'Hannover',
  'DENI058' => 'Ostfries. Inseln',
  'DENI059' => 'Elbmündung',
  'DENI060' => 'Wendland',
  'DENI062' => 'Lüneburger Heide',
  'DENI063' => 'Altes Land',
  'DENI067' => 'Osnabrück-Verkehr',
  'DENI068' => 'Göttingen-Verkehr',
  'DENI070' => 'Salzgitter-Drütte',
  'DENI071' => 'Barbis-Verkehr',
  'DENI075' => 'Braunschweig-Verkehr',
  'DENI077' => 'Solling-Süd',
  'DENI143' => 'Oldenburg Heiligengeistwall',
  'DENI157' => 'Wolfsburg Heßlinger Straße',
  'DENW002' => 'Datteln-Hagem',
  'DENW006' => 'Lünen-Niederaden',
  'DENW008' => 'Dortmund-Eving',
  'DENW010' => 'Unna-Königsborn',
  'DENW015' => 'Marl-Sickingmühle',
  'DENW021' => 'Bottrop-Welheim',
  'DENW022' => 'Gelsenkirchen-Bismarck',
  'DENW024' => 'Essen-Vogelheim',
  'DENW029' => 'Hattingen-Blankenstein',
  'DENW030' => 'Wesel-Feldmark',
  'DENW034' => 'Duisburg-Walsum',
  'DENW038' => 'Mülheim-Styrum',
  'DENW040' => 'Duisburg-Buchholz',
  'DENW042' => 'Krefeld-Linn',
  'DENW043' => 'Essen-Ost Steeler Straße',
  'DENW053' => 'Köln-Chorweiler',
  'DENW058' => 'Hürth',
  'DENW059' => 'Köln-Rodenkirchen',
  'DENW062' => 'Bonn-Auerberg',
  'DENW064' => 'Simmerath (Eifel)',
  'DENW065' => 'Netphen (Rothaargebirge)',
  'DENW066' => 'Nettetal-Kaldenkirchen',
  'DENW067' => 'Bielefeld-Ost',
  'DENW068' => 'Soest-Ost',
  'DENW071' => 'Düsseldorf-Lörick',
  'DENW074' => 'Niederzier',
  'DENW078' => 'Ratingen-Tiefenbroich',
  'DENW079' => 'Leverkusen-Manfort',
  'DENW080' => 'Solingen-Wald',
  'DENW081' => 'Borken-Gemen',
  'DENW082' => 'Düsseldorf Corneliusstraße',
  'DENW094' => 'Aachen-Burtscheid',
  'DENW095' => 'Münster-Geist',
  'DENW096' => 'Mönchengladbach-Rheydt',
  'DENW100' => 'Mönchengladbach Düsseldorfer Straße',
  'DENW101' => 'Dortmund Steinstraße',
  'DENW112' => 'Duisburg Kardinal-Galen-Straße',
  'DENW114' => 'Wuppertal-Langerfeld',
  'DENW116' => 'Krefeld (Hafen)',
  'DENW131' => 'Duisburg Kiebitzmühlenstraße',
  'DENW133' => 'Hagen Graf-von-Galen-Ring',
  'DENW134' => 'Essen Gladbecker Straße',
  'DENW136' => 'Dortmund Brackeler Straße',
  'DENW179' => 'Schwerte',
  'DENW180' => 'Grevenbroich-Gustorf',
  'DENW181' => 'Warstein',
  'DENW182' => 'Elsdorf-Berrendorf',
  'DENW188' => 'Oberhausen Mülheimer Straße 117',
  'DENW189' => 'Wuppertal Gathe',
  'DENW200' => 'Bielefeld Detmolder Straße',
  'DENW206' => 'Solingen Konrad-Adenauer-Straße',
  'DENW207' => 'Aachen Wilhelmstraße',
  'DENW208' => 'Gelsenkirchen Kurt-Schumacher-Straße',
  'DENW211' => 'Köln Clevischer Ring 3',
  'DENW212' => 'Köln Turiner Straße',
  'DENW247' => 'Essen-Schuir (LANUV)',
  'DENW254' => 'Duisburg Bergstraße 48',
  'DENW259' => 'Mönchengladbach Friedrich-Ebert-Straße',
  'DENW260' => 'Münster Weseler Straße',
  'DENW301' => 'Mülheim Hofackerstraße 46-48',
  'DENW307' => 'Kamp-Lintfort Eyller-Berg-Straße',
  'DENW329' => 'Jackerath',
  'DENW337' => 'Jüchen-Hochneukirch',
  'DENW338' => 'Duisburg-Bruckhausen',
  'DENW351' => 'Gelsenkirchen Grothusstraße',
  'DENW355' => 'Leverkusen Gustav-Heinemann-Str.',
  'DENW359' => 'Mönchengladbach-Wanlo',
  'DENW367' => 'Gladbeck Goethestraße',
  'DENW374' => 'Recklinghausen-Hochlarmark',
  'DERP001' => 'Ludwigshafen-Oppau',
  'DERP003' => 'Ludwigshafen-Mundenheim',
  'DERP007' => 'Mainz-Mombach',
  'DERP009' => 'Mainz-Zitadelle',
  'DERP010' => 'Mainz-Parcusstraße',
  'DERP011' => 'Mainz-Rheinallee',
  'DERP012' => 'Mainz-Große Langgasse',
  'DERP013' => 'Westpfalz-Waldmohr',
  'DERP014' => 'Hunsrück-Leisel',
  'DERP015' => 'Westeifel Wascheid',
  'DERP016' => 'Westerwald-Herdorf',
  'DERP017' => 'Pfälzerwald-Hortenkopf',
  'DERP019' => 'Kaiserslautern-Rathausplatz',
  'DERP020' => 'Trier-Ostallee',
  'DERP021' => 'Neuwied-Hafenstraße',
  'DERP022' => 'Bad Kreuznach-Bosenheimer Straße',
  'DERP023' => 'Worms-Hagenstraße',
  'DERP024' => 'Koblenz-Friedrich-Ebert-Ring',
  'DERP025' => 'Wörth-Marktplatz',
  'DERP026' => 'Frankenthal-Europaring',
  'DERP028' => 'Westerwald-Neuhäusel',
  'DERP041' => 'Ludwigshafen-Heinigstraße',
  'DERP045' => 'Koblenz-Hohenfelder Straße',
  'DERP046' => 'Neuwied-Hermannstraße',
  'DERP047' => 'Trier-Pfalzel',
  'DERP053' => 'Speyer-Nord',
  'DERP060' => 'Pirmasens-Innenstadt',
  'DESH001' => 'Altendeich',
  'DESH006' => 'Schleswig',
  'DESH008' => 'Bornhöved',
  'DESH013' => 'Fehmarn',
  'DESH014' => 'St.-Peter-Ording',
  'DESH015' => 'Itzehoe',
  'DESH016' => 'Barsbüttel',
  'DESH022' => 'Flensburg',
  'DESH023' => 'Lübeck-St. Jürgen',
  'DESH025' => 'Itzehoe Lindenstr.',
  'DESH027' => 'Kiel-Bahnhofstr. Verk.',
  'DESH028' => 'Ratzeburg',
  'DESH030' => 'Norderstedt',
  'DESH033' => 'Kiel-Max-Planck-Str.',
  'DESH035' => 'Brunsbüttel-Cuxhavener Straße',
  'DESH052' => 'Kiel-Theodor-Heuss-Ring',
  'DESH053' => 'Lübeck Moislinger Allee',
  'DESH055' => 'Lübeck Fackenburger Allee',
  'DESH056' => 'Eggebek',
  'DESL001' => 'Berus',
  'DESL002' => 'Bexbach Schule',
  'DESL003' => 'Dillingen City',
  'DESL006' => 'Lauterbach',
  'DESL010' => 'Saarbrücken-Burbach',
  'DESL011' => 'Saarbrücken-Eschberg',
  'DESL012' => 'Saarbrücken-City',
  'DESL013' => 'Saarlouis-Fraulautern',
  'DESL017' => 'Völklingen-City Stadionstr.',
  'DESL018' => 'Sulzbach',
  'DESL019' => 'Biringen',
  'DESL020' => 'Saarbrücken-Verkehr',
  'DESN001' => 'Annaberg-Buchholz',
  'DESN004' => 'Bautzen',
  'DESN006' => 'Borna',
  'DESN011' => 'Chemnitz-Mitte',
  'DESN017' => 'Freiberg',
  'DESN019' => 'Glauchau',
  'DESN020' => 'Görlitz',
  'DESN024' => 'Klingenthal',
  'DESN025' => 'Leipzig-Mitte',
  'DESN045' => 'Zittau-Ost',
  'DESN049' => 'Carlsfeld',
  'DESN051' => 'Radebeul-Wahnsdorf',
  'DESN052' => 'Zinnwald',
  'DESN053' => 'Fichtelberg',
  'DESN059' => 'Leipzig-West',
  'DESN061' => 'Dresden-Nord',
  'DESN074' => 'Schwartenberg',
  'DESN075' => 'Plauen-Süd',
  'DESN076' => 'Collmberg',
  'DESN077' => 'Leipzig Lützner Str. 36',
  'DESN079' => 'Niesky',
  'DESN080' => 'Schkeuditz',
  'DESN081' => 'Plauen-DWD',
  'DESN082' => 'Leipzig-Thekla',
  'DESN083' => 'Chemnitz-Leipziger Str.',
  'DESN084' => 'Dresden-Bergstr.',
  'DESN091' => 'Zwickau-Werdauer Str.',
  'DESN092' => 'Dresden-Winckelmannstr.',
  'DESN093' => 'Brockau',
  'DESN104' => 'Chemnitz Hans-Link-Straße',
  'DEST002' => 'Burg',
  'DEST011' => 'Wernigerode/Bahnhof',
  'DEST015' => 'Bitterfeld/Wolfen',
  'DEST028' => 'Zeitz',
  'DEST029' => 'Bernburg',
  'DEST039' => 'Brocken',
  'DEST044' => 'Halberstadt',
  'DEST050' => 'Halle/Nord',
  'DEST066' => 'Wittenberg/Bahnstrasse',
  'DEST075' => 'Halle/Merseburger Strasse',
  'DEST077' => 'Magdeburg/West',
  'DEST089' => 'Zartau/Waldstation',
  'DEST090' => 'Leuna',
  'DEST091' => 'Dessau Albrechtsplatz',
  'DEST092' => 'Wittenberg/Dessauer Strasse',
  'DEST095' => 'Aschersleben',
  'DEST098' => 'Unterharz / Friedrichsbrunn',
  'DEST101' => 'Halberstadt/Friedenstrasse',
  'DEST102' => 'Halle/Paracelsusstr.',
  'DEST103' => 'Magdeburg Schleinufer',
  'DEST104' => 'Domäne Bobbe',
  'DEST105' => 'Stendal Stadtsee',
  'DEST106' => 'Goldene Aue (Roßla)',
  'DEST108' => 'Weißenfels/Am Krug',
  'DEST112' => 'Magdeburg/Guericke-Stra.',
  'DETH005' => 'Saalfeld',
  'DETH009' => 'Gera Friedericistr.',
  'DETH011' => 'Altenburg Theaterplatz',
  'DETH013' => 'Eisenach Wernebrg.Str',
  'DETH018' => 'Nordhausen',
  'DETH020' => 'Erfurt Krämpferstr.',
  'DETH026' => 'Dreißigacker',
  'DETH027' => 'Neuhaus',
  'DETH036' => 'Greiz Mollbergstr.',
  'DETH041' => 'Jena Dammstr.',
  'DETH042' => 'Possen',
  'DETH043' => 'Erfurt Bergstr.',
  'DETH060' => 'Zella-Mehlis',
  'DETH061' => 'Hummelshain',
  'DETH072' => 'Suhl F.-König-Str',
  'DETH083' => 'Weimar Steubenstr.',
  'DETH091' => 'Mühlhausen Wanfrieder Str',
  'DETH093' => 'Weimar Schwanseestr.',
  'DETH095' => 'Mühlhausen Bastmarkt',
  'DETH117' => 'Erfurt Bautzener Weg',
  'DEUB001' => 'Westerland',
  'DEUB004' => 'Schauinsland',
  'DEUB005' => 'Waldhof',
  'DEUB028' => 'Zingst',
  'DEUB029' => 'Schmücke',
  'DEUB030' => 'Neuglobsow',
  'DEUB046' => 'Forellenbach',
);

##############################################################################


sub Initialize($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  $hash->{DefFn}        = "FHEM::uba::Define";
  $hash->{UndefFn}      = "FHEM::uba::Undefine";
  $hash->{GetFn}        = "FHEM::uba::Get";
  $hash->{AttrFn}       = "FHEM::uba::Attr";
  $hash->{NotifyFn}     = "FHEM::uba::Notify";
  $hash->{DbLog_splitFn}= "FHEM::uba::DbLog_splitFn";
  $hash->{AttrList}     = "FHEM::uba::disable:0,1 ".
                          "pollutants ".
                          "stationPM10 ".
                          "stationSO2 ".
                          "stationO3 ".
                          "stationNO2 ".
                          "stationCO ".
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
  $hash->{POLLUTION} = $station_names{$a[2]};
  $hash->{NOTIFYDEV}      = "global,$name";

  CommandAttr(undef,$name . ' stateFormat PM10 µg/m³') if (AttrVal($name,'stateFormat','none') eq 'none');
  CommandAttr(undef,$name . ' pollutants CO,NO2,O3,PM10,SO2') if (AttrVal($name,'pollutants','none') eq 'none');

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

  
  my ($now) = time;
  my $lastupdate = int($now-(24*60*60)-(strftime("%M",localtime($now))*60)-(strftime("%S",localtime($now))));
  my $enddate = int($lastupdate+(24*60*60));
  

  my ($pollutant,$station,$scope,$url);
  my @pollutants = split( ',', AttrVal($name,"pollutants","CO,NO2,O3,PM10,SO2") );

  foreach $pollutant (@pollutants) {
    $lastupdate = ReadingsVal( $name, ".lastUpdate".$pollutant, int($now-(24*60*60)-(strftime("%M",localtime($now))*60)-(strftime("%S",localtime($now)))) );
    $enddate = int($lastupdate+(24*60*60));
    $enddate = int($now) if ($enddate > $now);
    $scope = ($pollutant eq "CO") ? "8SMW" : "1SMW";
    $station = AttrVal($name,"station".$pollutant,$hash->{helper}{STATION});
    $url="http://www.umweltbundesamt.de/js/uaq/data/stations/measuring?pollutant[]=$pollutant&scope[]=$scope&station[]=$station&group[]=pollutant&range[]=".($lastupdate+1800).",$enddate";

    HttpUtils_NonblockingGet({
      url => $url,
      noshutdown => 1,
      timeout => 10,
      hash => $hash,
      type => $pollutant,
      range => $lastupdate,
      callback => \&ParseUBA
    });

  }

  Log3 ($name, 3, "Getting $pollutant data from URL: $url");
}

sub ParseUBA($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  if( $err )
  {
    Log3 $name, 1, "$name: URL error for ".$param->{type}." from ".$param->{range}.": ".$err;
    if(ReadingsVal($name,'state','error') ne "error"){
      RemoveInternalTimer($hash, "uba_GetUpdateUBA");
      InternalTimer(int(gettimeofday()+600), "uba_GetUpdateUBA", $hash);
    } else {
      RemoveInternalTimer($hash, "uba_GetUpdateUBA");
      InternalTimer(int(gettimeofday()+3600), "uba_GetUpdateUBA", $hash);
    }
    readingsSingleUpdate($hash,'state','error',1);
    return undef;
  }
  elsif( $data eq "" ){
    Log3 $name, 2, "Received no data for ".$param->{type}." from after ".FmtDateTime($param->{range}+1800);
    my $twentyfour = int(time)-(24*60*60);
    readingsSingleUpdate( $hash, ".lastUpdate".$param->{type}, $twentyfour, 0 ) if($param->{range} < $twentyfour);
    Log3 $name, 2, "Skipping missing readings before ".FmtDateTime($twentyfour) if($param->{range} < $twentyfour);
    return undef;    
  }
  elsif( $data !~ m/^{.*}$/ ){
    Log3 $name, 2, "$name: JSON error for UBA (".$param->{type}." from ".$param->{range}.")";
    my $nextupdate = int(gettimeofday())+600;
    if(ReadingsVal($name,'state','error') ne "error"){
      RemoveInternalTimer($hash, "uba_GetUpdateUBA");
      InternalTimer(int(gettimeofday()+600), "uba_GetUpdateUBA", $hash);
    } else {
      RemoveInternalTimer($hash, "uba_GetUpdateUBA");
      InternalTimer(int(gettimeofday()+3600), "uba_GetUpdateUBA", $hash);
    }
    readingsSingleUpdate($hash,'state','error',1);
    return undef;  
  }
  
  WriteReadings($hash,$data,$param);
}

sub WriteReadings($@) {
  my ($hash,$data,$param)    = @_;
  
  my $name = $hash->{NAME};
  my $json = eval { JSON->new->utf8(0)->decode($data) };
  if($@)
  {
    Log3 $name, 2, "$name: JSON evaluation error for UBA (".$param->{type}." from ".$param->{range}.") ".$@;
 
    if(ReadingsVal($name,'state','error') ne "error"){
      RemoveInternalTimer($hash, "uba_GetUpdateUBA");
      InternalTimer(int(gettimeofday()+600), "uba_GetUpdateUBA", $hash);
    } else {
      RemoveInternalTimer($hash, "uba_GetUpdateUBA");
      InternalTimer(int(gettimeofday()+3600), "uba_GetUpdateUBA", $hash);
    }
    readingsSingleUpdate($hash,'state','error',1);
    return undef;  
  }

  my $timescope = $json->{time_scope}[0];
  my $lastdata = $param->{range};

  my $set = 0;
  my $received = 0;
  
  foreach my $datapoint (@{$json->{data}[0]}) {
    my $value = @{$datapoint}[0];
    $set++;
    next if(!defined($value) or $value <= 0);
    $received++;
    $value *= 1000 if($param->{type} eq "CO" && int($value) <= 100);
    my $time = $param->{range} + ($timescope * $set);
    Log3 $name, 4, FmtDateTime( $time ).": ".$param->{type}." $value µg/m³ (from ".$param->{range}.")";
    $lastdata = $time;
    
    readingsBeginUpdate($hash);
    $hash->{".updateTimestamp"} = FmtDateTime($time);
    readingsBulkUpdate( $hash, $param->{type}, $value );
    $hash->{CHANGETIME}[0] = FmtDateTime($time);
    readingsEndUpdate($hash,1);

  }

  Log3 $name, 5, "JSON data for ".$param->{type}."\n".Dumper($json);

  if($received > 0)
  {
    Log3 $name, 3, "Received $received values for ".$param->{type}." from after ".FmtDateTime($param->{range}+1800);
    readingsSingleUpdate( $hash, ".lastUpdate".$param->{type}, $lastdata, 0 );
    readingsSingleUpdate( $hash, "lastUpdate".$param->{type}, FmtDateTime($lastdata), 0 ) if(AttrVal($name, "showTimeReadings", 0) eq 1);
  } else {
    my $twentyfour = int(time)-(24*60*60);
    readingsSingleUpdate( $hash, ".lastUpdate".$param->{type}, $twentyfour, 0 ) if($lastdata < $twentyfour);
    Log3 $name, 2, "Skipping missing readings before ".FmtDateTime($twentyfour) if($lastdata < $twentyfour);
  }

  my $nextupdate = gettimeofday()+$hash->{helper}{INTERVAL};
  RemoveInternalTimer($hash, "uba_GetUpdate");
  InternalTimer($nextupdate, "uba_GetUpdate", $hash);

  return undef;
}

sub Attr(@)
{
  my ($cmd, $device, $attribName, $attribVal) = @_;
  my $hash = $defs{$device};

  $attribVal = "" if (!defined($attribVal));

  if($cmd eq "set" && $attribName eq "userPassODL")
  {
    CommandAttr( undef,$hash->{NAME} . ' userPassODL ' . encrypt($attribVal) )
  }
  
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
  This modul provides air quality data for Germany, measured by UBA stations.<br/>
  <br/><br/>
  Disclaimer:<br/>
  Users are responsible for compliance with the respective terms of service, data protection and copyright laws.<br/><br/>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; uba &lt;uba_stationid&gt;</code>
    <br>
    Example: <code>define airdata uba DEBY123</code>
    <br>&nbsp;
    <li><code>uba_stationid</code>
      <br>
      UBA Station ID, see <a href="http://www.umweltbundesamt.de/daten/luftbelastung/aktuelle-luftdaten#/stations">umweltbundesamt.de/luftbelastung</a>
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
      <li><code>CO</code>
      <br>
      CO data in µg/m³, 8h median value<br/>
      </li><br>
      <li><code>NO2</code>
      <br>
      NO2 data in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>O3</code>
      <br>
      O3 data in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>PM10</code>
      <br>
      PM10 data in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>SO2</code>
      <br>
      SO2 data in µg/m³, 1h median value<br/>
      </li><br>
      <li><code>lastUpdateXX</code>
      <br>
      Last update time for pollutant XX (only if enabled through showTimeReadings)<br/>
      </li><br>
    </ul>
  <br>
   <b>Attributes</b>
   <ul>
      <li><code>disable</code>
         <br>
         Disables the module
      </li><br>
      <li><code>pollutants</code>
         <br>
         Comma separated list of pollutants to get data for. (default: CO,NO2,O3,PM10,SO2)
      </li><br>
      <li><code>showTimeReadings</code>
         <br>
         Create visible readings for last update times
      </li><br>
      <li><code>stationCO</code>
         <br>
         Station id to be used for getting CO data (ignoring module definition)
      </li><br>
      <li><code>stationNO2</code>
         <br>
         Station id to be used for getting NO2 data (ignoring module definition)
      </li><br>
      <li><code>stationO3</code>
         <br>
         Station id to be used for getting O3 data (ignoring module definition)
      </li><br>
      <li><code>stationPM10</code>
         <br>
         Station id to be used for getting PM10 data (ignoring module definition)
      </li><br>
      <li><code>stationSO2</code>
         <br>
         Station id to be used for getting SO2 data (ignoring module definition)
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
    "UBS"
  ],
  "release_status": "unstable",
  "license": "GPL_2",
  "author": [
    "Florian Asche <fhem@florian-asche.de>"
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
