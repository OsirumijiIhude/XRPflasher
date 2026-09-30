/* Progressive enhancement only. No trackers, third-party runtime or form backend. */
(() => {
  'use strict';
  const root = document.documentElement;
  const media = window.matchMedia('(prefers-reduced-motion: reduce)');
  let savedMotion = null;
  try { savedMotion = localStorage.getItem('mecca-motion'); } catch (_) { /* Storage can be blocked. */ }
  let motionOff = media.matches || savedMotion === 'off';
  const running = new Set();
  const motionButtons = [...document.querySelectorAll('.motion-toggle')];
  function applyMotion() {
    root.classList.toggle('motion-off', motionOff);
    motionButtons.forEach(button => {
      button.textContent = `Motion: ${motionOff ? 'off' : 'on'}`;
      button.setAttribute('aria-pressed', String(motionOff));
      button.setAttribute('aria-label', motionOff ? 'Turn animations on' : 'Turn animations off');
    });
    if (motionOff) {
      running.forEach(animation => animation.cancel());
      running.clear();
      document.body.classList.remove('hero-enter');
    }
  }
  function animate(element, frames, options = {}) {
    if (!element || motionOff || typeof element.animate !== 'function') return;
    const animation = element.animate(frames, { duration: 620, easing: 'cubic-bezier(.22,1,.36,1)', ...options });
    running.add(animation);
    const remove = () => running.delete(animation);
    animation.addEventListener('finish', remove, { once: true });
    animation.addEventListener('cancel', remove, { once: true });
    return animation;
  }
  applyMotion();
  media.addEventListener('change', event => { motionOff = event.matches || savedMotion === 'off'; applyMotion(); });
  motionButtons.forEach(button => button.addEventListener('click', () => {
    motionOff = !motionOff;
    savedMotion = motionOff ? 'off' : 'on';
    try { localStorage.setItem('mecca-motion', savedMotion); } catch (_) { /* Optional preference only. */ }
    applyMotion();
  }));
  if (!motionOff) {
    document.body.classList.add('hero-enter');
    window.setTimeout(() => document.body.classList.remove('hero-enter'), 1400);
  }

  // Animate on arrival without ever hiding server-rendered content in CSS.
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;
        const element = entry.target;
        animate(element, [{ opacity: 0.16, transform: 'translateY(20px)' }, { opacity: 1, transform: 'translateY(0)' }]);
        observer.unobserve(element);
      });
    }, { threshold: 0.07, rootMargin: '0px 0px -18px 0px' });
    document.querySelectorAll('[data-reveal]').forEach(element => observer.observe(element));
  }

  // One scheduled scroll update, with no permanent animation loop.
  const progress = document.querySelector('.reading-progress');
  let scrollFrame = 0;
  function drawProgress() {
    scrollFrame = 0;
    const max = document.documentElement.scrollHeight - window.innerHeight;
    if (progress) progress.style.transform = `scaleX(${max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0})`;
  }
  function queueProgress() { if (!scrollFrame) scrollFrame = requestAnimationFrame(drawProgress); }
  window.addEventListener('scroll', queueProgress, { passive: true });
  window.addEventListener('resize', queueProgress, { passive: true });
  window.addEventListener('pageshow', queueProgress);
  queueProgress();

  // Mobile menu retains keyboard focus and closes on Escape, link activation or resize.
  const menuButton = document.querySelector('.menu-toggle');
  const mobileMenu = document.querySelector('#mobile-menu');
  const main = document.querySelector('main');
  const footer = document.querySelector('.site-footer');
  function closeMenu(restoreFocus = false) {
    if (!menuButton || !mobileMenu) return;
    mobileMenu.hidden = true;
    menuButton.setAttribute('aria-expanded', 'false');
    menuButton.setAttribute('aria-label', 'Open menu');
    document.body.classList.remove('menu-open');
    if (main) main.inert = false;
    if (footer) footer.inert = false;
    if (restoreFocus) menuButton.focus();
  }
  menuButton?.addEventListener('click', () => {
    if (menuButton.getAttribute('aria-expanded') === 'true') { closeMenu(true); return; }
    mobileMenu.hidden = false;
    menuButton.setAttribute('aria-expanded', 'true');
    menuButton.setAttribute('aria-label', 'Close menu');
    document.body.classList.add('menu-open');
    if (main) main.inert = true;
    if (footer) footer.inert = true;
    animate(mobileMenu, [{ opacity: 0, transform: 'translateY(-8px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 300 });
    mobileMenu.querySelector('a')?.focus({ preventScroll: true });
  });
  mobileMenu?.querySelectorAll('a').forEach(link => link.addEventListener('click', () => closeMenu()));
  document.addEventListener('keydown', event => {
    if (menuButton?.getAttribute('aria-expanded') !== 'true') return;
    if (event.key === 'Escape') { event.preventDefault(); closeMenu(true); }
    if (event.key === 'Tab') {
      const items = [menuButton, ...mobileMenu.querySelectorAll('a')];
      const first = items[0], last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    }
  });
  window.matchMedia('(min-width: 721px)').addEventListener('change', event => { if (event.matches) closeMenu(); });
  window.addEventListener('pageshow', () => closeMenu());

  // Service index: semantic tabs, focus navigation and image cross-fades.
  const tabs = [...document.querySelectorAll('[data-service-tab]')];
  function selectTab(index, focus = false) {
    tabs.forEach((tab, i) => {
      const isActive = i === index;
      const panel = document.getElementById(tab.getAttribute('aria-controls'));
      tab.setAttribute('aria-selected', String(isActive));
      tab.tabIndex = isActive ? 0 : -1;
      tab.classList.toggle('is-active', isActive);
      if (panel) { panel.hidden = !isActive; panel.classList.toggle('is-active', isActive); }
      if (isActive && panel) animate(panel, [{ opacity: 0.2, transform: 'translateY(7px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 480 });
    });
    if (focus) tabs[index]?.focus({ preventScroll: true });
  }
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => { if (tab.getAttribute('aria-selected') !== 'true') selectTab(index); });
    tab.addEventListener('keydown', event => {
      let next = index;
      if (event.key === 'ArrowDown') next = (index + 1) % tabs.length;
      else if (event.key === 'ArrowUp') next = (index + tabs.length - 1) % tabs.length;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = tabs.length - 1;
      else return;
      event.preventDefault(); selectTab(next, true);
    });
  });

  // The dial offers only the five mileage intervals stated in the company profile.
  const serviceIntervals = [5000, 10000, 20000, 40000, 80000];
  document.querySelectorAll('[data-gauge]').forEach(gauge => {
    const needle = gauge.querySelector('.gauge-needle');
    const number = gauge.querySelector('.odometer-number');
    const output = gauge.querySelector('.gauge-output');
    let numberAnimation;
    gauge.querySelectorAll('input[type=radio]').forEach(input => input.addEventListener('change', () => {
      if (!input.checked) return;
      const selected = Number(input.value), index = serviceIntervals.indexOf(selected);
      if (index < 0) return;
      needle.style.transform = `rotate(${-135 + index * 67.5}deg)`;
      numberAnimation?.cancel();
      number.textContent = selected.toLocaleString('en-GB');
      output.textContent = `${selected.toLocaleString('en-GB')} kilometres service`;
      numberAnimation = animate(number, [{ opacity: 0.1, transform: 'translateY(45%)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 570 });
      const section = gauge.closest('.maintenance-block');
      section?.querySelectorAll('[data-interval-link]').forEach(link => {
        link.href = `/contact/?enquiry=Scheduled%20maintenance&interval=${selected}`;
      });
    }));
  });

  document.querySelectorAll('.diagnostics-accordions details').forEach(details => {
    details.addEventListener('toggle', () => {
      if (details.open) animate(details.querySelector('.details-body'), [{ opacity: 0.15, transform: 'translateY(-5px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 330 });
      queueProgress();
    });
  });

  // Search and category filter combine, including a clear empty state.
  const search = document.querySelector('#part-search');
  const filters = [...document.querySelectorAll('[data-filter]')];
  const cards = [...document.querySelectorAll('.part-card')];
  const resultCount = document.querySelector('#part-results');
  const emptyState = document.querySelector('.empty-state');
  let currentFilter = 'all';
  function filterParts() {
    const term = (search?.value || '').trim().toLowerCase();
    let count = 0;
    cards.forEach(card => {
      const visible = (currentFilter === 'all' || card.dataset.category === currentFilter) && (!term || card.textContent.toLowerCase().includes(term));
      const wasHidden = card.hidden;
      card.hidden = !visible;
      if (visible) {
        count++;
        if (wasHidden) animate(card, [{ opacity: 0.2, transform: 'translateY(8px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 330 });
      }
    });
    if (resultCount) resultCount.textContent = `${count} ${count === 1 ? 'category' : 'categories'}`;
    if (emptyState) emptyState.hidden = count !== 0;
    queueProgress();
  }
  filters.forEach(button => button.addEventListener('click', () => {
    currentFilter = button.dataset.filter;
    filters.forEach(filter => { const selected = filter === button; filter.classList.toggle('is-active', selected); filter.setAttribute('aria-pressed', String(selected)); });
    filterParts();
  }));
  search?.addEventListener('input', filterParts);
  document.querySelector('#reset-parts')?.addEventListener('click', () => {
    search.value = '';
    filters.find(filter => filter.dataset.filter === 'all')?.click();
    search.focus();
  });

  // No values from query strings are inserted as HTML. Only supported options are accepted.
  const form = document.querySelector('#enquiry-form');
  const dialog = document.querySelector('#enquiry-dialog');
  if (form && dialog) {
    form.querySelector('button[type="submit"]').disabled = false;
    const params = new URLSearchParams(location.search);
    const requested = params.get('enquiry');
    const allowedEnquiries = ['Scheduled maintenance','Spare parts','General repairs','Diagnostics','Panel beating and respraying'];
    if (allowedEnquiries.includes(requested)) {
      [...form.querySelectorAll('input[name=enquiry]')].find(input => input.value === requested).checked = true;
    }
    const interval = Number(params.get('interval'));
    const part = params.get('part');
    const partCategories = ['Service kits','Engine components','Suspension systems','Body parts','Braking systems','Cooling systems','Exhaust systems','Fluids and lubricants'];
    if (serviceIntervals.includes(interval)) form.elements.message.value = `I would like to enquire about a ${interval.toLocaleString('en-GB')} km service.`;
    else if (partCategories.includes(part)) form.elements.message.value = `I would like to enquire about ${part.toLowerCase()}.`;
    if (params.get('branch') === 'Gweru') form.querySelector('input[name=branch][value=Gweru]').checked = true;
    // Reject whitespace-only values with an actionable native validation message.
    const requiredText = [form.elements.name, form.elements.phone, form.elements.vehicle];
    function validateText(input) {
      const value = input.value.trim();
      const invalid = !value || (input.name === 'phone' && value.replace(/\D/g, '').length < 7);
      input.setCustomValidity(invalid ? (input.name === 'phone' ? 'Enter a phone number with at least 7 digits.' : 'Please complete this field.') : '');
    }
    requiredText.forEach(input => input.addEventListener('input', () => validateText(input)));
    let lastFocus;
    function closeDialog() { dialog.close(); lastFocus?.focus({ preventScroll: true }); }
    form.addEventListener('submit', event => {
      event.preventDefault();
      requiredText.forEach(validateText);
      if (!form.reportValidity()) return;
      const data = new FormData(form);
      const name = String(data.get('name') || '').trim();
      const phone = String(data.get('phone') || '').trim();
      const vehicle = String(data.get('vehicle') || '').trim();
      if (!name || !vehicle || phone.length < 7) return;
      const branch = data.get('branch') === 'Gweru' ? 'Gweru' : 'Harare';
      const enquiry = allowedEnquiries.includes(data.get('enquiry')) ? data.get('enquiry') : 'General enquiry';
      const message = [`Hello MECCA ${branch},`, '', `Name: ${name}`, `Phone: ${phone}`, `Vehicle: ${vehicle}`, `Enquiry: ${enquiry}`, '', String(data.get('message') || '').trim()].join('\n').trim();
      dialog.querySelector('.enquiry-review').textContent = message;
      const whatsapp = branch === 'Gweru' ? '263776817256' : '263772533723';
      const email = branch === 'Gweru' ? 'Gweru@meccaauto.co.zw' : 'admin@meccautogen.com';
      dialog.querySelector('#send-whatsapp').href = `https://wa.me/${whatsapp}?text=${encodeURIComponent(message)}`;
      dialog.querySelector('#send-email').href = `mailto:${email}?subject=${encodeURIComponent(`MECCA ${branch}: ${enquiry}`)}&body=${encodeURIComponent(message)}`;
      lastFocus = document.activeElement;
      dialog.showModal();
      animate(dialog, [{ opacity: 0.3, transform: 'translateY(12px)' }, { opacity: 1, transform: 'translateY(0)' }], { duration: 300 });
      dialog.querySelector('.dialog-close').focus({ preventScroll: true });
    });
    dialog.querySelector('.dialog-close').addEventListener('click', closeDialog);
    dialog.querySelector('.edit-enquiry').addEventListener('click', closeDialog);
    dialog.addEventListener('cancel', () => { requestAnimationFrame(() => lastFocus?.focus({ preventScroll: true })); });
    dialog.addEventListener('click', event => {
      if (event.target !== dialog) return;
      const rect = dialog.getBoundingClientRect();
      if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) closeDialog();
    });
  }
})();
