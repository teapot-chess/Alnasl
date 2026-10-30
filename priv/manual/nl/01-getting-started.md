# Aan de slag

Alnasl leest de elektronische borden in een speelzaal, leidt uit de stand van de stukken de zetten af en stuurt de zetten en de kloktijden naar de uitslagensite terwijl er gespeeld wordt. Dit hoofdstuk zegt wat het is, op welke twee manieren je het draait, hoe je het installeert en wat je nakijkt voor de eerste ronde.

> [!NOTE] Het beslist nooit over een resultaat
> Een mat op het bord of twee koningen in het midden is een voorstel. Jij bevestigt het. Een bord voert nergens zelf een resultaat in.

## Wat Alnasl doet {#what-alnasl-does}

Wie tegen wie speelt, hoort Alnasl van OpenPairings. Wat elk bord zag, gaat daarheen terug, naast de paring. De zetten en de klokken gaan naar de uitslagensite (OpenResults), waar de toeschouwers ze volgen. Alnasl bewaart eerst alles zelf, dus een zaal zonder internet verliest niets: wat niet kon worden verstuurd, gaat in volgorde weg zodra de verbinding terug is.

Je werkt ermee in een browser, op het kastje zelf of op je laptop in de zaal. De pagina's staan in de balk links, in groepen:

| Groep | Pagina | Waarvoor |
| --- | --- | --- |
| Spelen | Live | Het scherm tijdens het spel: de borden van deze zaal, als tegels of als lijst |
| Spelen | Borden | Wat er aangesloten is, de tafelnummers, "Klaar voor ronde N?" |
| Spelen | Partijen | Partijen als tekst (PGN): inlezen, toewijzen, vergelijken, exporteren |
| Versturen | Resultaten | Wat naar de uitslagensite en de andere bestemmingen gegaan is, en wat nog wacht |
| Beheren | Zalen | De zalen waar je bij hoort, hun bruggen en mensen |
| Beheren | Instellingen | In onderdelen: toernooien, koppelingen, uitslagen en Lichess, dit kastje, toegang, updates, geavanceerd |
| Terugkijken | Logboek | Wat er gebeurd is, in zinnen |
| Terugkijken | Opnames | Alles wat de borden zeiden, ruw, om nog eens te bekijken |
| | Help | Deze handleiding |

Dat zijn alle pagina's, zoals de volledige modus ze toont. Een nieuwe installatie start in de eenvoudige modus, die de basis in het menu houdt en de rest één schakelaar verder: zie [Eenvoudig of alles](#simple-mode).

Bovenaan de balk: de naam van het kastje (op de server: "server") en, als je meer dan één zaal hebt, de zaalkiezer. Onderaan: de accountknop, met je taal, het kleurthema en Afmelden.

Op een telefoon wordt de balk een strook bovenaan (de naam, de zaalkiezer en de accountknop) en staan de pagina's in een strook onderaan: Live, Borden, Resultaten en Meer, met de rest. Op een telefoon ontbreekt niets; het is één tik verder.

Meldingen (de uitslagensite is niet bereikbaar, een bord speelt buiten zijn toernooi, een vraag over tafels, een nieuwe versie) staan boven de pagina, hoogstens twee tegelijk. De rest wacht achter "nog 1 melding"; druk erop om ze te zien.

Een pagina of lijst waar nog niets in staat, zegt dat in een zin, en zegt wat er iets in brengt: een koppeling voor de toernooien, een brug voor de borden van een zaal, een bord voor een ronde. Is er één voor de hand liggende volgende stap, dan brengt een knop je erheen.

Instellingen is in onderdelen, elk met een eigen adres en een lijst ernaast (een keuzelijst op een telefoon): de **Installatiewizard** (zie [hieronder](#setup-wizard)), **Toernooien** (een regel per toernooi; open er een voor de details, zijn zalen en tafels en het automatisch starten; die met borden in deze zaal staan bovenaan, de afgelopen en de niet begonnen zitten achter een schakelaar), **Koppelingen** (codes en accountkoppelingen, een regel elk met een menu voor Testen, Opnieuw proberen en Verwijderen, en "+ Toevoegen"), **Uitslagen en Lichess**, **Dit kastje** (op de server **Deze server**), **Toegang** en **Updates** (alleen een kastje) en **Geavanceerd** (de tracker, voor beheerders). Een onderdeel dat jouw editie of rol niet kan gebruiken, wordt niet getekend.

## De installatiewizard {#setup-wizard}

Het eerste onderdeel van Instellingen is de **Installatiewizard**. Zolang niet elke stap gedaan is, opent Instellingen daar; daarna opent het op Toernooien, en de wizard blijft in de lijst staan voor de volgende wijziging. Hij is per zaal: open hem op de server in elke zaal, met de zaalkiezer bovenaan.

Hij begint met een paar vragen: hoe de zaal eruitziet (één zaal met één toernooi, één zaal met meerdere toernooien, of meerdere zalen of ruimtes), hoeveel Arkab-bruggen (op de server altijd; op een kastje alleen voor de ruimtes buiten de zijne), ongeveer hoeveel borden, en wat je er nog bij wilt: uitslagen voor toeschouwers, een Lichess-uitzending, een printstation, een omroeper, en op een kastje telefoons en laptops achter een pincode. Eén kabelketting neemt tot twaalf borden; meer borden is een tweede ketting op een eigen poort.

Daarna somt hij de stappen voor precies die zaal op, in volgorde, met elk één knop die naar de plaats gaat waar je de stap doet. De eerste stap die niet gedaan is, is de huidige. Elk vinkje komt uit wat Alnasl echt heeft, niet uit iemand die op Volgende drukt:

| Stap | Afgevinkt als |
| --- | --- |
| De zalen maken (server, meerdere zalen) | Je zoveel zalen ziet als je opgaf |
| De borden aansluiten (kastje) | Het kastje zoveel borden op zijn eigen poorten heeft als je opgaf |
| Arkab installeren | Een brug van deze zaal minstens één keer verbonden is geweest |
| Brug 1 van N, 2 van N... | Die brug bij deze zaal aangesloten is en verbonden is geweest; "nu niet verbonden" als ze plat ligt |
| Borden die binnenkomen (server) | De zaal zoveel borden heeft als bruggen maal borden per brug |
| Het toernooi of de toernooien koppelen | Zoveel toernooien uit OpenPairings in deze zaal staan |
| Tafels per toernooi (meerdere toernooien) | Hoogstens één toernooi "elke vrije tafel" houdt; de andere hebben een reeks |
| De borden nummeren | Elk bord van de zaal een tafelnummer heeft |
| Uitslagen voor toeschouwers | Een toernooi hier een uitslagenpagina en zijn relaissleutel heeft |
| Lichess | Een toernooi hier een Lichess-ronde en zijn token heeft |
| Telefoons en laptops (kastje) | Andere machines in de zaal binnengelaten zijn (Instellingen, Toegang) |
| Printstation, omroeper | Je ze zelf als gedaan aanduidt: Polis en Nunki praten met OpenPairings, niet met Alnasl, dus Alnasl kan ze niet zien |

De koppelcode komt uit OpenPairings: open het toernooi, dan Instellingen, Live borden, en druk op "Nieuwe code". Een stap waar je met jouw rol niets aan kunt doen, houdt zijn vinkje, verliest zijn knop en zegt wie het wel kan. Alleen de eigenaar van de zaal beantwoordt de vragen; "De antwoorden wijzigen" stelt ze opnieuw en de vinkjes lopen gewoon door.

## Twee manieren om het te draaien {#two-ways}

Het is beide keren hetzelfde programma. Het verschil is waar het draait en wat eraan hangt.

**Een kastje in de zaal.** Een kleine computer (een Raspberry Pi, een mini-pc, de laptop van de arbiter) waaraan de borden hangen met een usb- of seriële kabel. Het leest ze zelf. Dit is het gewone geval, en het werkt zonder internet.

**De gehoste server.** Hetzelfde programma draait op een server, op alnasl.zerotwo.cloud. Een server heeft zelf geen borden: hij heeft geen poorten om te lezen. In plaats daarvan neemt hij **bruggen** aan: Arkab, een klein programma in een zaal dat de borden daar leest en via internet doorsturen (zie [Bruggen](03-bridges.md)). De pagina's zijn die je kent: de ronde, de partijen, de correcties. Het verschil is dat elke pagina altijd vraagt wie je bent, en dat accounts alleen op uitnodiging bestaan (zie [Accounts, zalen en rollen](06-accounts-and-halls.md)).

De server laat weg wat alleen een kastje kan, in plaats van het grijs te maken: borden toevoegen en de lijst met seriële poorten op de pagina Borden, simulatorborden, het paneel Updates en meestarten met Windows, de pincode en het zaalnetwerk, en de naam van het kastje. Instellingen, Deze server, zegt welke editie je ziet, onder "Deze kopie van Alnasl"; de onderdelen Toegang en Updates zijn er helemaal niet.

> [!TIP] Welke kies je?
> Borden in je eigen zaal en je wilt het simpel: een kastje in de zaal. Meerdere zalen, een arbiter thuis, of niemand wil een computer in de zaal: bruggen en de server. Je kunt ze samen gebruiken, want één brug mag meer dan één server voeden.

## Installeren {#installing}

**Windows.** Alnasl-Setup.exe installeert alleen voor jou, zonder beheerder, en zet "Alnasl" in het Startmenu. Het programma is niet ondertekend, dus de eerste keer zegt Windows "Windows heeft je pc beschermd": kies "Meer info" en dan "Toch uitvoeren". Het kleine Alnasl-venster is het programma: sluit je het, dan stopt Alnasl, en zolang het gestopt is worden de borden niet gelezen. Er is ook een zipbestand dat niets installeert: uitpakken en Alnasl.exe starten.

**Linux en de Raspberry Pi.** Eén regel installeert Alnasl als dienst die met het kastje opstart (64-bit; Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm, of nieuwer):

```
curl -fsSL https://github.com/teapot-chess/Alnasl/releases/latest/download/install.sh | sudo sh
```

**Mac.** Download alnasl-macos-aarch64.zip voor een Mac met een Apple-chip (M1 en later; voor Intel-Macs is er geen build), open het en sleep Alnasl naar Programma's. Apple heeft het nog niet ondertekend, dus de eerste keer weigert macOS het te openen: klik in Systeeminstellingen, Privacy en beveiliging, op "Toch openen" bij de melding over Alnasl. Alnasl afsluiten (Cmd-Q) vraagt eerst bevestiging, want zolang het gestopt is worden de borden niet gelezen.

Open daarna de site in een browser: op het kastje zelf via `http://localhost:4040`; vanaf een laptop in het netwerk van de zaal via het adres van het kastje met dezelfde poort (Borden en Instellingen, Toegang, tonen het, met een QR-code voor een telefoon, zodra andere machines binnen mogen).

### Updaten {#updating}

Het kastje vraagt om het halfuur of er een nieuwere versie is en meldt dat bovenaan de pagina. Er wordt niets gedownload voor je ja zegt bij Instellingen, Updates, waar ook staat hoe groot de download is. Het herstart niet terwijl er een partij bezig is, tenzij je aandringt: de zetten tijdens de herstart worden niet gelezen. "Later" vraagt morgen opnieuw; "Niet meer vragen" stopt het zoeken, en Instellingen zet het weer aan.

Wat er per versie veranderd is, staat op dezelfde pagina onder de knop, zodat niemand Alnasl hoeft te verlaten om het te lezen. De notities die bij je versie horen staan er meteen; de nieuwere worden bij GitHub opgehaald zodra je het onderdeel opent, en zes uur bewaard zodat het internet van de zaal niet twee keer wordt gevraagd. Je eigen versie is gemarkeerd, nieuwere zijn gemarkeerd en open, oudere zijn ingeklapt. Zonder internet krijg je de notities die bij je versie horen en een kalme opmerking dat alles wat nieuwer is internet nodig heeft. Een klein "Bekijk op GitHub"-linkje blijft voor wie het origineel wil, al hoort een zaalkiosk dat niet nodig te hebben.

### Waar je gegevens staan {#where-your-data-is}

Niet in de map van het programma. Windows: `%LOCALAPPDATA%\AlnaslData` (typ dat in de adresbalk van Verkenner). Linux, geïnstalleerd: `/var/lib/alnasl`. Mac: `~/Library/Application Support/AlnaslData`. Daarin staan de database, de PGN van elke partij, de ruwe opnames en de sleutels en codes die je geplakt hebt. Updaten en verwijderen laten die map met rust; opnieuw installeren vindt ze terug. Om naar een andere computer te verhuizen kopieer je die map terwijl Alnasl gestopt is.

Instellingen, Dit kastje, "Deze kopie van Alnasl", zegt de versie, hoe deze kopie gestart is en waar de gegevensmap staat. Een tweede kopie die anders gestart is op dezelfde computer heeft een eigen gegevensmap: eigen borden, nummers en toernooien.

## Een kastje zonder netwerk {#setup-hotspot}

Een kastje zonder kabel en zonder wifi die hij kent, is vanuit de zaal niet te bereiken. Daarom maakt hij zijn eigen wifi-netwerk. Maak er verbinding mee met je telefoon of laptop, dan gaat de installatiepagina van het kastje open. Daar kies je de wifi van de zaal. Op een Arkab-kastje stel je daar ook de pincode op afstand in en plak je de koppellink. Hiervoor heeft het kastje geen scherm en geen toetsenbord nodig.

Het netwerk heet `Alnasl-setup-XXXX`; de vier tekens achteraan horen bij het kastje. Het is altijd met een wachtwoord beveiligd (WPA2), nooit open. Het verschijnt ongeveer een minuut nadat het kastje start als er geen netwerk is, en het verdwijnt zodra het kastje op de wifi van de zaal zit. Met een netwerkkabel is het er de eerste tien minuten na het starten, daarna verdwijnt het. Zolang het aan staat, zegt de statusregel op het scherm van het kastje `setup hotspot`.

### Er verbinding mee maken {#joining-the-hotspot}

Het wachtwoord staat in het bestand `alnasl-hotspot.txt` op de kleine FAT-partitie van de sd-kaart, de partitie die op elke pc gewoon zichtbaar is. Open het bestand en lees de regel `PASSWORD=`. Het kastje schrijft daar bij de eerste start zelf een wachtwoord in (10 tekens, zonder 0, O, 1 of l om je in de war te brengen), en de naam van het netwerk op de regel `SSID=`.

Of scan `alnasl-hotspot-qr.png`, de QR-afbeelding naast dat bestand, met de camera van je telefoon. De telefoon maakt dan verbinding zonder dat je iets typt. Druk hem af en plak hem op de kast.

Zodra je verbonden bent, opent de telefoon de installatiepagina vanzelf. Doet hij dat niet, open dan `http://10.42.0.1` in de browser en typ zelf het `http://` ervoor. Op een iPhone: komt de pagina nooit, kies dan Dit netwerk vergeten, verbind opnieuw en controleer of Automatisch inloggen aan staat voor dat netwerk.

### Een eigen wachtwoord {#hotspot-password}

Voor de eerste start kun je zelf een wachtwoord achter `PASSWORD=` typen: 8 tot 63 gewone toetsenbordtekens, zonder aanhalingstekens. Wil je op elk kastje hetzelfde wachtwoord, schrijf dan op elke kaart hetzelfde. Een wachtwoord dat te kort of te lang is, vervangt het kastje door een ander, en het bestand zegt dat erbij.

Later wijzigen kan op dezelfde manier. Het geldt vanaf de volgende start. `HOTSPOT=off` zet de hotspot helemaal uit.

Wie het wachtwoord kan lezen of de QR-code kan scannen, kan de installatiepagina openen, en die kan de wifi van het kastje wijzigen. Hou de sticker bij het kastje, niet op een gedeelde schijf.

### Op de installatiepagina {#setup-page}

- **Wifi.** De pagina zet de netwerken op een rij die hij ziet. Kies het netwerk van de zaal of typ de naam, vul het wachtwoord in en druk op Verbinden. Het kastje verlaat zijn eigen netwerk en probeert het. Lukt het, dan blijft de hotspot uit, en de regel die bij het einde van `alnasl-hotspot.txt` met `# Box:` begint, zegt waar het kastje naartoe is gegaan. Lukt het niet, dan komt de hotspot binnen ongeveer een minuut terug, en de pagina zegt waarom: verkeerd wachtwoord, netwerk niet gevonden, geweigerd of geen adres.
- **Pincode op afstand en koppellink (alleen een Arkab-kastje).** Zie de volgende sectie, of stel de pincode hier in.
- **Alleen lezen.** De rol van het kastje, zijn adressen, waar je hem daarna bereikt, en een link "open in je browser" naar `http://10.42.0.1/`, voor als het aanmeldvenster te krap is.

### De pincode op afstand van Arkab {#arkab-pin}

Op een Arkab-kastje kan een browser elders in de zaal Arkab beheren nadat je een pincode hebt ingetypt. Om de pincode in te stellen, open je `alnasl-arkab-pin.txt` op de bootpartitie en typ je hem achter `PIN=`. Steek daarna de kaart terug in het kastje. De pincode moet 4 tot 64 tekens zijn. Letters, cijfers en andere gewone toetsenbordtekens zijn goed. Hij mag niet beginnen of eindigen met een spatie of een aanhalingsteken, en hij mag geen besturingstekens bevatten. De woorden `remove` en `verwijderen` zijn geen pincode: die betekenen "de pincode weghalen".

Het kastje neemt de pincode over bij de volgende start. Hij geeft hem door aan Arkab en maakt de regel `PIN=` daarna weer leeg, zodat de pincode niet zomaar op de kaart te lezen is. Onderaan het bestand schrijft het kastje een regel `# Last result:`. Daarin staat of de pincode is ingesteld, waarom hij is geweigerd, of dat hij nog niet doorgegeven kon worden en bij de volgende start opnieuw wordt geprobeerd. Lees die regel als je de kaart in een pc steekt.

Om de pincode weg te halen, schrijf je `PIN=remove` en start je het kastje. Je kunt de pincode ook op de installatiepagina instellen, zonder de kaart aan te raken.

## Voor de ronde {#before-the-round}

Elke keer dezelfde korte lijst. Bij elke stap zegt een pagina in woorden wat er mis is, als er iets mis is.

1. Instellingen, Koppelingen: plak de koppelcode uit OpenPairings; geef dan bij Toernooien aan welke tafels in welk toernooi spelen (zie [OpenPairings, OpenResults en Lichess](05-openpairings-and-openresults.md)). Druk op "Verbinding testen" (in het menu Acties van de koppeling).
2. Borden: elk bord moet een andere toestand tonen dan "Geen signaal", en zijn plaatje moet kloppen met de stukken erop.
3. Borden: de kolom "Beginstelling" moet bij elk bord "Juist" zeggen. Zo niet, dan noemt ze de stukken en velden. Een koning en dame die omgewisseld staan, komt het meest voor.
4. Een bord met een klok is pas "Juist" als de klok dat ook is: rechts van het bord, de hendel omhoog aan de kant van wit, zodat de tijd van wit eerst loopt.
5. Borden: geef elk bord zijn tafelnummer (zie [Borden en poorten](02-boards-and-ports.md)).
6. Borden: "Klaar voor ronde N?" moet "Klaar" zeggen. Zo niet, dan somt het per bord op wat er mis is.
7. Live: elke tegel moet "Wacht op begin" zeggen.

## Taal en kleuren {#language-and-colours}

De site bestaat in het Engels en het Nederlands. De taal is de jouwe, niet die van het kastje: kies ze in het accountmenu (de knop onderaan de balk, op een telefoon rechtsboven). Met een account wordt de keuze bij het account bewaard en volgt ze je naar elke browser; zonder accounts wordt ze in die browser bewaard. Hoe dan ook verandert niemand anders van taal, en deze handleiding volgt de jouwe.

Wie niets koos, leest de standaardtaal van Alnasl. Een beheerder stelt die in bij Instellingen, "Dit kastje" ("Deze server"), Standaardtaal.

De kleuren komen in dezelfde thema's als OpenResults: Papier, Nacht, Bord, Leisteen en Hoog contrast, en Volg het toestel, dat het toestel volgt. Kies in het accountmenu, bij Kleurthema; dat is de enige plek. De keuze geldt alleen voor die browser. Hoog contrast is voor een projector achteraan de zaal.

Er kunnen meer thema's bij als themapakketten: een map per thema, in de map `themes` binnen de gegevensmap. Bij de volgende keer laden staan ze na de ingebouwde thema's. Ze staan er alleen in de volledige modus ([Eenvoudig of alles](#simple-mode)); een pakket dat je eerder koos, blijft in de eenvoudige modus werken. Een pakket dat Alnasl niet wil laden, staat in het grijs in de lijst, met de reden.

## Eenvoudig of alles {#simple-mode}

Alnasl start in de **eenvoudige modus**: de basis om een zaal te draaien, en verder niets in het menu. Dat is Live (de borden en hun partijen), Borden (wat er aangesloten is, de tafelnummers, nummeren door de borden aan te raken, "Klaar voor ronde N?"), Zalen (mensen en bruggen), Instellingen met de wizard, Toernooien, Koppelingen en, op een kastje, Updates, en deze handleiding. De verbindingsbadges in de balk zeggen nog steeds of de resultaten de uitslagensite bereiken.

De rest staat één schakelaar verder: **Alles tonen**, in het accountmenu (en onderaan de balk, of onder Meer op een telefoon, zolang de eenvoudige modus aan staat). Daarmee komen Partijen (PGN), Resultaten (wat verstuurd is en wat wacht), Logboek, Opnames, de telefoonpagina om een bord te vinden, fair play voor de eigenaar van de zaal, de andere onderdelen van Instellingen (Uitslagen en Lichess, Dit kastje, Toegang, Geavanceerd) en de themapakketten in het kleurmenu erbij. Zet je hem weer uit, dan verdwijnen ze uit het menu.

In de eenvoudige modus wordt niets verwijderd en verandert niemands rechten: een link naar een pagina die alleen in de volledige modus staat, opent een korte melding die dat zegt, met de schakelaar erop. Druk erop en de pagina is er.

Waar de keuze bewaard wordt: met een account bij het account, dus iedereen heeft de zijne; een account dat nooit koos, volgt het kastje. Op een kastje zonder accounts wordt ze voor het kastje bewaard, dus elke browser in de zaal volgt ze.

Een kastje of server die al in gebruik was voor de eenvoudige modus bestond, houdt na de update elke pagina: die start in de volledige modus. Een nieuwe installatie start in de eenvoudige modus.

## Kleine schermen {#small-screens}

Op een scherm van 4 tot 7 inch (800x480, 1024x600, 720x720) tekent Alnasl vanzelf een compacte indeling: één strook bovenaan met de pagina's links en de zaal en het account rechts, geen balk opzij, grotere knoppen, en kleinere tegels op Live met het bordnummer, de toestand, de spelers, de klokken en de laatste zet of het resultaat. Het stellingsdiagram wacht op een groter scherm; de eigen pagina van het bord heeft het nog.

De andere pagina's volgen. De eigen pagina van een bord toont het bord met de namen en klokken ernaast en de zetten in een kolom daarnaast, alles op één scherm; alleen de zettenlijst schuift. Blijft de partij in Alnasl, dan krimpt die melding tot één regel met haar knop; een gewijzigde paring houdt haar volledige tekst en staat bovenaan. Instellingen en Zalen staan in één kolom met grotere tekst en velden, en de lijst van zalen toont elke zaal als een kaart. De rondleiding zet haar stappen onder de strook bovenaan, aan de kant weg van waar ze naar wijzen.

Alnasl beslist op de grootte van het venster. Een klein scherm met veel pixels lijkt daardoor op een monitor: kies **Klein scherm** in het accountmenu, bij Scherm, en de compacte indeling blijft aan op dat scherm. **Groot scherm** houdt ze uit, **Automatisch** laat het venster weer beslissen. De keuze geldt alleen voor die browser.

De eenvoudige modus en de compacte indeling staan los van elkaar: een grote tv kan de eenvoudige modus tonen, een klein scherm kan alles tonen.

## De rondleiding {#the-tour}

De eerste keer dat je de site opent (met accounts: de eerste keer dat je aanmeldt), biedt een kaartje in de hoek een rondleiding aan. Ze loopt door de pagina's in de volgorde waarin je een zaal inricht en speelt: de plaatsen, de installatiewizard, bruggen, OpenPairings koppelen, toernooien en hun tafels, de borden en hun nummers, de controle voor de ronde, Live, Resultaten en fair play. In de eenvoudige modus slaat de rondleiding de pagina's over die alleen in de volledige modus staan. Elke stap wijst aan waar het over gaat, zegt in een zin of twee waarvoor het dient, en linkt naar het stuk van deze handleiding dat de rest vertelt. Een stap op een andere pagina brengt je daarheen.

Je ziet alleen de stappen voor wat je rol je laat gebruiken: een kijker krijgt de installatiewizard en de bruggen niet te zien, en fair play alleen de eigenaar van de zaal. Waar een pagina nog niets heeft om aan te wijzen (geen borden, geen toernooien), zegt de stap wat er zal verschijnen.

Gebruik **Volgende** en **Terug** (of de pijltjestoetsen), of **Rondleiding overslaan**; Escape sluit ze ook. Druk je op het kaartje op **Nu niet**, dan wordt ze niet meer aangeboden. Wil je ze later volgen, open dan het accountmenu (de knop onderaan de balk, op een telefoon rechtsboven) en kies **Rondleiding volgen**. Met accounts wordt bij je account bewaard of je ze volgde; op een kastje zonder accounts geldt dat voor het kastje.

## Woorden in deze handleiding {#words}

De schermen en deze handleiding gebruiken één woord per ding:

| Woord | Betekent |
| --- | --- |
| Alnasl | Het programma, waar het ook draait. Een zin die de server ook toont, zegt "Alnasl", niet "het kastje" |
| kastje | Alnasl op een eigen computer in een zaal, die borden leest op zijn eigen poorten |
| server | De gehoste Alnasl op alnasl.zerotwo.cloud, die borden leest via bruggen |
| brug | Arkab, naast de borden van een zaal, die ze naar een kastje of de server stuurt |
| zaal | Een ruimte met tafels en borden; elke pagina gaat over één zaal |
| het eigen toernooi van de zaal | Waar de borden van een zaal spelen als geen paring ze noemt |
| koppeling | Een koppelcode of een accountkoppeling met OpenPairings |
| uitslagensite | OpenResults, waar toeschouwers de partijen volgen |
| uitslagenpagina | De pagina van één toernooi op de uitslagensite |
| Resultaten | De pagina in de balk die toont wat verstuurd is en wat wacht |
| live bord | Een elektronisch bord; de schermen noemen nooit een merk |
| arbiter, kijker | Rollen in een zaal: een arbiter verbetert en start rondes, een kijker kijkt |

Een partij die "in Alnasl blijft", wordt hier bewaard en nergens heen gestuurd; het logboek zegt "Arbiter in Alnasl" als iemand een partij via deze pagina's veranderde.
