(function () {
  const page = location.pathname.split('/').pop() || 'index.html';
  // Presentation switch: retain league records and administration for a later return.
  const teamsVisible = false;
  document.documentElement.dataset.barlTeams = teamsVisible || page === 'admin.html' ? 'visible' : 'paused';
  document.documentElement.dataset.barlPage = page.replace('.html', '') || 'index';
  const fontLink = document.createElement('link');
  fontLink.rel = 'stylesheet';
  fontLink.href = 'https://fonts.googleapis.com/css2?family=Barlow+Condensed:ital,wght@0,700;0,800;1,700;1,800&family=DM+Mono:wght@400;500&family=Space+Grotesk:wght@400;500;600;700&display=swap';
  document.head.append(fontLink);
  const themeLink = document.createElement('link');
  themeLink.rel = 'stylesheet';
  themeLink.href = 'barl-theme.css?v=11';
  document.head.append(themeLink);
  if (page === 'index.html') {
    const dashboardStyles = document.createElement('link');
    dashboardStyles.rel = 'stylesheet';
    dashboardStyles.href = 'dashboard.css?v=3';
    document.head.append(dashboardStyles);
  }
  const activePage = ['profiles.html', 'career.html', 'driver.html'].includes(page) ? 'claim.html' : page;
  const links = [
    ['index.html', 'Home'],
    ['standings.html', 'Standings'],
    ['results.html', 'Results'],
    ['schedule.html', 'Schedule'],
    ['rules.html', 'Rules'],
    ['claim.html', 'Drivers'],
    ['join.html', 'Season 2'],
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
        <div class="ticker-item"><span class="ticker-badge">Next Race</span> <span id="header-next-race">Live season schedule</span></div>
        <div class="ticker-sep"></div>
        <div class="ticker-item"><span class="ticker-badge red">Last Race Winner</span> <span id="header-last-winner">Published race results</span></div>
      </div>
    </div>
    <nav class="nav site-nav" aria-label="Primary navigation">
      <a href="index.html" class="nav-logo"><img src="assets/brand/barl-logo.png" alt="BARL Racing League"></a>
      <ul class="nav-links">${linkMarkup}</ul>
      <a href="auth.html" class="nav-cta">Log In / Join →</a>
      <button class="nav-hamburger" id="hamburger" type="button" aria-label="Open menu" aria-expanded="false" aria-controls="nav-drawer"><span></span><span></span><span></span></button>
    </nav>
    <div class="nav-drawer" id="nav-drawer">${drawerMarkup}<a href="auth.html" class="drawer-cta">Log In / Join →</a></div>`;

  window.addEventListener('barl:home-summary', event => {
    const winner = document.getElementById('header-last-winner');
    if (winner) winner.textContent = `${event.detail.winnerName} · #${event.detail.number} · ${event.detail.race.track_short}`;
  });
  const currentNav = document.querySelector('nav.nav');
  const currentDrawer = document.querySelector('.nav-drawer');
  const currentTicker = document.querySelector('.ticker');
  const mount = document.createElement('header');
  mount.className = 'site-header';
  mount.innerHTML = headerMarkup;
  if (currentTicker || currentNav) (currentTicker || currentNav).before(mount);
  else document.body.prepend(mount);
  currentTicker?.remove();
  currentNav?.remove();
  currentDrawer?.remove();

  window.__leagueDataReady?.then(data => {
    const races = [...(data.races || [])].sort((a,b) => a.race_number - b.race_number);
    const next = races.find(race => !['completed','voided'].includes(race.status));
    if (next) document.getElementById('header-next-race').textContent = `Race ${next.race_number} — ${next.track_name}`;
    const last = [...races].reverse().find(race => race.status === 'completed' && (data.results || []).some(result => result.race_id === race.id && result.start_status === 'started' && result.finish_status !== 'disqualified' && result.finish_position === 1));
    const winner = (data.results || []).find(result => result.race_id === last?.id && result.start_status === 'started' && result.finish_status !== 'disqualified' && result.finish_position === 1);
    const driver = (data.drivers || []).find(driver => driver.id === winner?.driver_id);
    if (winner) document.getElementById('header-last-winner').textContent = `${driver?.display_name || driver?.gamertag || 'Winner'} · #${winner.car_number} · ${last.track_short}`;
  }).catch(() => {});

  const button = mount.querySelector('.nav-hamburger');
  const drawer = mount.querySelector('.nav-drawer');
  function setMenuOpen(open) {
    button.classList.toggle('open', open);
    drawer.classList.toggle('open', open);
    if (open) drawer.style.top = `${mount.querySelector('.nav').getBoundingClientRect().bottom}px`;
    button.setAttribute('aria-expanded', String(open));
    button.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  }
  button.addEventListener('click', () => setMenuOpen(button.getAttribute('aria-expanded') !== 'true'));
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && button.getAttribute('aria-expanded') === 'true') {
      setMenuOpen(false);
      button.focus();
    }
  });
  document.addEventListener('click', event => {
    if (!button.contains(event.target) && !drawer.contains(event.target)) setMenuOpen(false);
  });

  const footer = document.querySelector('footer');
  if (footer) {
    footer.className = 'footer site-footer';
    footer.innerHTML = `<div class="footer-brand"><img src="assets/brand/barl-logo.png" alt="BARL Racing League"><p>Below average name. Serious league racing.</p></div><div class="footer-links">${links.map(([href, label]) => `<a href="${href}">${label}</a>`).join('')}</div><div class="footer-meta">NASCAR 26 · Season 1 · PlayStation · Xbox · PC</div>`;
  }
})();
