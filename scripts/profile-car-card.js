(function () {
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  function render({ driverId, name, number, team, season }) {
    const art = window.BARLCarArt[String(number)];
    const color = art?.color || '#ffc906';
    const label = number == null ? '—' : String(number);
    const numberBadge = art?.numberImage
      ? `<img src="${escape(art.numberImage)}" alt="Car number ${escape(label)}" width="104" height="88" decoding="async">`
      : escape(label);
    const image = art
      ? `<img class="grid-car-image" src="assets/cars/${escape(number)}.webp" alt="Number ${escape(number)} ${escape(art.sponsor)} ${escape(art.make)}" width="1536" height="1024" loading="lazy" decoding="async">`
      : `<div class="grid-car-pending"><span>${escape(team || 'BARL Racing')}</span><strong>${escape(label)}</strong><small>Car artwork coming soon</small></div>`;
    return `<a class="grid-driver-card" href="career.html?id=${encodeURIComponent(driverId)}" target="_top" style="--livery:${color}" aria-label="View ${escape(name)}, car ${escape(label)}, career profile">
      <div class="grid-driver-heading"><div><p class="grid-driver-team">${escape(team || 'Team pending')}</p><h2>${escape(name)}</h2></div><span class="grid-driver-number">${numberBadge}</span></div>
      <div class="grid-car-stage">${image}</div>
      <div class="grid-driver-footer"><span>${escape(art ? `${art.make} / ${art.sponsor}` : 'BARL / Season ' + (season || '—'))}</span><span class="grid-profile-link">Driver profile <b aria-hidden="true">↗</b></span></div>
    </a>`;
  }

  window.BARLCarCards = Object.freeze({ render });
})();
