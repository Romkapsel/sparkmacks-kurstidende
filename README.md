# Sparkmack's Kurstidende

*Finans- og handelsblad for auksjonshuset · Grundlagt 1890 · «Tid er penger, kompis!»*

En addon for **World of Warcraft Forever** som gjør auksjonshuset om til en finansavis. Sparkmack, en sleip og
pengegrisk goblin, sender budet sitt til AH etter dagens kurser og forteller deg hva du bør gjøre.

- **Forsiden – NYHETER:** råd om hva du bør legge ut, omprise eller la stå, med forventet gevinst etter AH-cut og deposit.
  Én knapp per handling – ingenting skjer uten at du klikker.
- **TIL AUKSJON:** alle auksjonene dine, om du er billigst eller underbudt, og hvor lenge det er igjen.
- **Bla om** med pila på høyre kant til **Børsen** (kupp på torget, mest omsatt) og **Hovedboken**
  (ukens regnskap, netto per dag og siste handler fra postkassen).
- Tooltip med kursnotering på alle varer i avisen.

## Installere

**Enklest – med automatiske oppdateringer:** bruk [WowUp](https://wowup.io) (gratis).
1. Åpne WowUp og velg World of Warcraft Forever.
2. *Get Addons* → *Install from URL* → lim inn `https://github.com/Romkapsel/sparkmacks-kurstidende` → *Install*.
3. WowUp sjekker selv etter nye versjoner og oppdaterer med ett klikk (eller automatisk, hvis du slår det på).

**For hånd:** last ned `Sparkmack-x.y.z.zip` under [Releases](https://github.com/Romkapsel/sparkmacks-kurstidende/releases),
pakk den ut i `World of Warcraft\_classic_beta_\Interface\AddOns\` (mappen skal hete `Sparkmack`) og start spillet på nytt.

## Bruk

1. Åpne AH – avisen legges fram.
2. **Send ut budet** – full skanning av AH (maks én gang per 15. minutt; det er Blizzards grense).
3. Følg rådene i NYHETER. Åpne fanen «Auctions» i AH én gang, så leser budet auksjonene dine.
4. Åpne postkassen innimellom – da fører budet salg, kjøp og utløpte auksjoner inn i Hovedboken.
5. **Send til trykken!** lagrer alt til disk (en kort `/reload`).

Kommandoer: `/spm avis` (åpne/lukke avisen), `/spm skann`, `/spm lagre`. Skaler avisen med håndtaket nede i
høyre hjørne eller Ctrl + musehjul.

## Godt å vite

- Addonen kjøper, poster og kansellerer **aldri** noe av seg selv. Hver handling krever ett klikk fra deg.
- Uten eget kursgrunnlag (`Data.lua`) antar Sparkmack 30 % sjanse for salg og kjenner ikke 7-dagers median ennå,
  så rådene er forsiktige, og «Kupp på torget» er tomt.

Lisens: MIT.
