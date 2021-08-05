export default setupSearch;

import FuzzySet from "./fuzzyset.js";

console.log(">> SEARCH");

function setupSearch(
  anchor,
  minScore = 0.5,
  showDeckTitles = true,
  showDeckSubtitles = false
) {
  var indexPath = Decker.meta.projectPath + "/index.json";
  fetch(indexPath)
    .then((res) => res.json())
    .then((index) => {
      setup(index, anchor, minScore, showDeckTitles, showDeckSubtitles);
    })
    .catch((err) => console.log("cannot load: index.json", err));
}

function setup(index, anchor, minScore, showDeckTitles, showDeckSubtitles) {
  anchor.innerHTML =
    document.documentElement.lang === "de"
      ? `<p><input class="search" placeholder="Suchbegriff eingeben" type="text"></p>
         <p><table class="search">
         <thead><tr><th>Wort</th><th>Foliensatz</th><th>Folie</th><th>Treffer</th></tr></thead>
         <tbody></tbody>
         </table></p>`
      : `<p><input class="search" placeholder="Looking for something?" type="text"></p>
         <p><table class="search">
         <thead><tr><th>Word</th><th>Deck</th><th>Slide</th><th>Hits</th></tr></thead>
         <tbody></tbody>
         </table></p>`;

  const search = anchor.querySelector("input.search");
  const table = anchor.querySelector("table.search");
  const results = anchor.querySelector("table.search tbody");
  const keys = Object.keys(index.index).map((k) => k.toString());
  const fuzzy = FuzzySet(keys);

  search.addEventListener("input", (e) => {
    // delete all rows in table body
    while (results.firstChild) {
      results.removeChild(results.firstChild);
    }

    // get matches from fuzzy set
    const matches = fuzzy.get(search.value, [], minScore);

    // create one table row per slide per match
    for (let match of matches) {
      const word = match[1];
      const exact = search.value == word;
      const found = exact ? `<b>${word}</b>` : `<i>${word}</i>`;
      let onSlides = index.index[word];

      // first: sort based on deck URL
      onSlides.sort((slide1, slide2) => {
        const deck1 = index.slides[slide1.slide].deckUrl;
        const deck2 = index.slides[slide2.slide].deckUrl;
        if (deck1 < deck2) return -1;
        if (deck1 > deck2) return 1;
        return 0;
      });

      // second: (stable) sort based on search count
      onSlides.sort((slide1, slide2) => slide2.count - slide1.count);

      for (let slide of onSlides) {
        const url = slide.slide;
        const count = slide.count;
        const sInfo = index.slides[url];
        const dInfo = index.decks[sInfo.deckUrl];

        let deck = "";
        if (showDeckTitles && dInfo.deckTitle) {
          deck += dInfo.deckTitle;
        }
        if (showDeckSubtitles && dInfo.deckSubtitle) {
          if (deck.length) deck += " &mdash; ";
          deck += dInfo.deckSubtitle;
        }

        let item = document.createElement("tr");
        item.innerHTML = `<td>${found}</td> 
        <td><a target="_blank" href="./${dInfo.deckUrl}">${deck}</a></td>
        <td><a target="_blank" href="./${url}">${sInfo.slideTitle}</a></td>
        <td>${count}</td>`;

        results.appendChild(item);
      }
    }
  });

  search.addEventListener("keyup", (e) => {
    if (e.key == "Escape") {
      search.value = "";
      while (results.firstChild) {
        results.removeChild(results.firstChild);
      }
    }
  });

  // if search elements are inside a <details> element, add some
  // convenience functionality
  const details = search.closest("details");
  if (details) {
    details.addEventListener("toggle", (evt) => {
      if (details.open) search.focus();
    });

    search.addEventListener("keyup", (e) => {
      if (e.key == "Escape") details.open = false;
    });
  }
}