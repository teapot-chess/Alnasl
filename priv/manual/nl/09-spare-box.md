# Een reservekastje

Een kastje in een zaal is een kleine computer, en kleine computers gaan stuk: een voeding, een geheugenkaart, een kop koffie. Dit hoofdstuk gaat over een kopie van de zaal in de cloud terwijl het kastje draait, en een tweede kastje ernaast dat met die kopie overneemt als het eerste stopt.

## Een reservekastje {#a-spare-box}

Twee kastjes, één zaal in de cloud:

- het **actieve** kastje leest de borden, zoals altijd, en stuurt elke zet, elke klokstand en elke uitslag meteen naar zijn zaal in de cloud. Het heeft de cloud niet nodig om de zaal te draaien: zonder lijn gaat het door en bewaart het wat het niet kon sturen;
- het **reservekastje** staat klaar. Het leest geen borden en stuurt niets. Het vraagt de cloud alleen om de paar seconden of het actieve kastje er nog is.

Als het actieve kastje langer stil is dan de cloud toelaat (45 seconden, tenzij de cloud anders zegt), of als iemand op **Overnemen** drukt, kopieert het reservekastje de zaal uit de cloud - de toernooien, de ronde, welk bord welke partij speelt, en elke zet tot de laatste die het actieve kastje stuurde - en draait het de zaal. Steek de borden in het reservekastje wanneer het overneemt: een bord wordt herkend aan zijn serienummer, dus het krijgt zijn eigen tafel en partij terug op welke poort het ook belandt.

Zetten die gespeeld zijn terwijl geen kastje draaide, zitten in de borden zelf; die teruglezen hoort bij wat er na een overname gebeurt.

De cloud is een reservekopie en de plek waar de overdracht gebeurt, geen tweede zaal. Er draait altijd maar één kastje een zaal.

## Een kastje koppelen aan een zaal {#pairing}

1. Open in de cloud de zaal, dan haar tabblad **Kastjes**, en druk op **Een kastje koppelen**. Je krijgt een code en een link, goed voor één kastje en vijftien minuten.
2. Open op het kastje **Cloud en reserve** (in het menu, onder Beheren), plak de link of typ de code, en druk op **Koppelen**.

Het kastje haalt zelf zijn eigen sleutel op en bewaart die in zijn gegevensmap. Niemand ziet hem, typt hem of kopieert hem. Een kastje dat zo gekoppeld wordt, begint als actief kastje, tenzij het ingesteld is om als reserve te beginnen. Koppel eerst het kastje dat de zaal draait, daarna het reservekastje op dezelfde manier; druk op het reservekastje op **Dit kastje reserve maken** als het niet als reserve begon.

Koppelen op het kastje vraagt de beheerder van het kastje. Koppelen in de cloud en **Overnemen** vragen een arbiter van de zaal; een kastje verwijderen vraagt haar eigenaar.

## Wat de statusregel zegt {#status}

Een gekoppeld kastje zegt in de balk bovenaan elke pagina hoe het ervoor staat:

- **Stuurt naar de cloud** - alles in orde;
- **Offline, 23 gebeurtenissen in de wachtrij** - de lijn ligt eruit. Het kastje draait de zaal verder en stuurt wat wacht, op volgorde, zodra de lijn terug is. De wachtrij overleeft een herstart;
- **Wachtrij vol** - het kastje heeft zoveel in de wachtrij gezet als het wil (50.000 gebeurtenissen). Op het kastje zelf gaat niets verloren; zodra de lijn terug is, stuurt het één keer zijn hele toestand in plaats van elke gemiste gebeurtenis;
- **Staat klaar als reserve** - dit is het reservekastje;
- **Een ander kastje nam over** - zie verder.

## Overnemen {#taking-over}

Op het reservekastje: **Cloud en reserve**, **Overnemen**. Of in de cloud: het tabblad **Kastjes** van de zaal, **Overnemen** naast het reservekastje. Hoe dan ook krijgt het reservekastje de zaal meteen, kopieert het haar, en begint het. Het kastje dat de zaal tot dan draaide, hoort het bij zijn volgende woord met de cloud, en stopt.

Een reservekastje neemt vanzelf over als het actieve kastje te lang stil is. Is het actieve kastje alleen van het internet afgesneden en draait het de zaal nog, dan heb je een tijdje twee kastjes voor één zaal; vink **Vanzelf overnemen** uit op het reservekastje als het internet in de zaal onbetrouwbaar is, en druk zelf op Overnemen als het kastje echt dood is.

Wat het reservekastje niet uit de cloud krijgt: de sleutels voor de uitslagensite, Lichess en het paringsprogramma. Die blijven op het kastje waaraan ze gegeven zijn. Verbind het reservekastje vóór het toernooi één keer met het paringsprogramma, zodat de uitslagen na een overname blijven binnenkomen.

## Een ander kastje nam over {#superseded}

Een kastje dat merkt dat een ander kastje zijn zaal draait, stopt: het leest geen borden, stuurt geen uitslagen, en zegt **Een ander kastje nam over**. Dat geldt ook als het na een lange tijd zonder lijn terugkomt met zetten die het nooit stuurde: de zaal is zonder dat kastje verdergegaan, en twee kastjes die één zaal schrijven is erger dan één kastje dat een paar zetten mist.

Het biedt één ding aan: **Klaarstaan als reserve**. Dan is het het reservekastje van het kastje dat overnam.

## Vertrekken {#leaving}

**De zaal verlaten** op het kastje vergeet de cloud en de sleutel; het kastje draait zijn zaal alleen, zoals voor het gekoppeld was. **Verwijderen** op het tabblad Kastjes van de zaal in de cloud doet hetzelfde van de andere kant: de sleutel werkt meteen niet meer, en het kastje merkt het bij zijn volgende woord.
