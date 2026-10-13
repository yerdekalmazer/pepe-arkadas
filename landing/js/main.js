// Pepe tanıtım sayfası: üst çubuk, çentik adası, video, kaydırınca belirme, indirme notu.
(() => {
  const bar = document.querySelector('[data-bar]');
  const hero = document.querySelector('.hero');

  // Koyu kancanın üstündeyken çubuk saydam; aşağıda buzlu krem.
  const solid = () => bar.classList.toggle('is-solid', window.scrollY > hero.offsetHeight - 80);
  solid();
  window.addEventListener('scroll', solid, { passive: true });

  // Çentik: üstüne gelince (ya da tıklayınca) Pepe'nin adası açılır.
  const notch = document.querySelector('[data-notch]');
  if (notch) {
    const set = open => notch.classList.toggle('is-open', open);
    notch.addEventListener('mouseenter', () => set(true));
    notch.addEventListener('mouseleave', () => set(false));
    notch.addEventListener('click', () => set(!notch.classList.contains('is-open')));
    notch.addEventListener('blur', () => set(false));
  }

  // Video: büyük oynat düğmesi; oynarken gizlenir.
  const player = document.querySelector('[data-player]');
  if (player) {
    const video = player.querySelector('video');
    player.querySelector('[data-play]').addEventListener('click', () => video.play());
    video.addEventListener('play', () => player.classList.add('is-playing'));
    video.addEventListener('pause', () => player.classList.remove('is-playing'));
  }

  // Kaydırınca yumuşak belirme.
  const items = document.querySelectorAll('.feat__copy, .shot, .video .player, .steps li, .grid3 > div, .faq details, .end__copy, .end__art');
  items.forEach(el => el.classList.add('reveal'));
  const io = new IntersectionObserver(entries => entries.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add('is-in'); io.unobserve(e.target); }
  }), { rootMargin: '0px 0px -12% 0px' });
  items.forEach(el => io.observe(el));

  // İndirme başlayınca kurulumun sonraki adımını hatırlat.
  const toast = document.querySelector('[data-toast]');
  let timer;
  document.querySelectorAll('[data-download]').forEach(a => a.addEventListener('click', () => {
    toast.classList.add('is-on');
    clearTimeout(timer);
    timer = setTimeout(() => toast.classList.remove('is-on'), 9000);
  }));
  toast.querySelector('[data-toast-close]').addEventListener('click', () => toast.classList.remove('is-on'));
})();
