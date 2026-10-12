(function () {
  const page = location.pathname.split('/').pop() || 'index.html';
  document.documentElement.dataset.barlPage = page.replace('.html', '') || 'index';
  const fontLink = document.createElement('link');
  fontLink.rel = 'stylesheet';
  fontLink.href = 'https://fonts.googleapis.com/css2?family=Audiowide&family=DM+Mono:wght@400;500&family=Space+Grotesk:wght@400;500;600;700&display=swap';
  document.head.append(fontLink);
  const themeLink = document.createElement('link');
  themeLink.rel = 'stylesheet';
  themeLink.href = 'barl-theme.css?v=4';
  document.head.append(themeLink);
  const activePage = ['profiles.html', 'career.html', 'driver.html'].includes(page) ? 'claim.html' : page;
  const links = [
    ['index.html', 'Home'],
    ['standings.html', 'Standings'],
    ['results.html', 'Results'],
    ['schedule.html', 'Schedule'],
    ['rules.html', 'Rules'],
    ['claim.html', 'Drivers'],
  ];
  const linkMarkup = links.map(([href, label]) =>
    `<li><a href="${href}"${activePage === href ? ' class="active" aria-current="page"' : ''}>${label}</a></li>`
  ).join('');
  const drawerMarkup = links.map(([href, label]) =>
    `<a href="${href}"${activePage === href ? ' class="active" aria-current="page"' : ''}>${label}</a>`
  ).join('');
  const headerMarkup = `
    <div class="ticker site-ticker">
      <div class="ticker-inner">
        <div class="ticker-item"><span class="ticker-badge">Next Race</span> <span id="ticker-next">Race 1 — Daytona International Speedway</span></div>
        <div class="ticker-sep"></div>
        <div class="ticker-item"><span class="ticker-badge">Season 1</span> <span data-season-summary>24 Spots · 8 Teams · <span id="season-race-count">8 Races</span></span></div>
      </div>
    </div>
    <nav class="nav site-nav" aria-label="Primary navigation">
      <a href="index.html" class="nav-logo"><img src="assets/brand/barl-logo.png" alt="BARL Racing League"></a>
      <ul class="nav-links">${linkMarkup}</ul>
      <a href="auth.html" class="nav-cta">Log In / Join →</a>
      <button class="nav-hamburger" id="hamburger" type="button" aria-label="Open menu" aria-expanded="false" aria-controls="nav-drawer"><span></span><span></span><span></span></button>
    </nav>
    <div class="nav-drawer" id="nav-drawer">${drawerMarkup}<a href="auth.html" class="drawer-cta">Log In / Join →</a></div>`;

  const currentNav = document.querySelector('nav.nav');
  const currentDrawer = document.querySelector('.nav-drawer');
  const currentTicker = document.querySelector('.ticker');
  // Page renderers still update these nodes after league data arrives.
  const tickerSummary = currentTicker?.querySelector('#ticker-text, #schedule-ticker-summary');
  const raceCount = currentTicker?.querySelector('#season-race-count');
  const mount = document.createElement('header');
  mount.className = 'site-header';
  mount.innerHTML = headerMarkup;
  if (tickerSummary) mount.querySelector('[data-season-summary]').replaceWith(tickerSummary);
  else if (raceCount) mount.querySelector('#season-race-count').replaceWith(raceCount);
  if (currentTicker || currentNav) (currentTicker || currentNav).before(mount);
  else document.body.prepend(mount);
  currentTicker?.remove();
  currentNav?.remove();
  currentDrawer?.remove();

  window.__leagueDataReady?.then(data => {
    const next = data.races.find(race => race.status !== 'completed' && race.status !== 'voided');
    mount.querySelector('#ticker-next').textContent = next
      ? `Race ${next.race_number} — ${next.track_name || next.track_short}`
      : data.races.length ? 'Season complete' : 'Schedule pending publication';
  }).catch(console.error);

  const button = mount.querySelector('.nav-hamburger');
  const drawer = mount.querySelector('.nav-drawer');
  button.addEventListener('click', () => {
    const open = button.classList.toggle('open');
    drawer.classList.toggle('open', open);
    if (open) drawer.style.top = `${mount.querySelector('.nav').getBoundingClientRect().bottom}px`;
    button.setAttribute('aria-expanded', String(open));
    button.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  });

  const footer = document.querySelector('footer');
  if (footer) {
    footer.className = 'footer site-footer';
    footer.innerHTML = `<div class="footer-brand"><img src="assets/brand/barl-logo.png" alt="BARL Racing League"><p>Below average name. Serious league racing.</p></div><div class="footer-links">${links.map(([href, label]) => `<a href="${href}">${label}</a>`).join('')}</div><div class="footer-meta">NASCAR 26 · Season 1 · PlayStation · Xbox · PC</div>`;
  }
})();
