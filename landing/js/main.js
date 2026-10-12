(() => {
  // ?durgun: hareketsiz inceleme modu (ekran görüntüsü almak için; adaya son hali çizilir).
  const still = new URLSearchParams(location.search).has("durgun");
  if (still) document.documentElement.classList.add("durgun");
  const reduce = still || window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));

  // ── Nav: kaydırınca yoğunlaşır
  const nav = $("[data-nav]");
  const onScroll = () => nav.classList.toggle("is-scrolled", window.scrollY > 24);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // ── Reveal: görünüme girince sıralı açılır
  const io = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      const siblings = $$(".reveal", e.target.parentElement).filter((el) => !el.classList.contains("is-in"));
      const i = Math.max(0, siblings.indexOf(e.target));
      e.target.style.transitionDelay = `${Math.min(i, 5) * 70}ms`;
      e.target.classList.add("is-in");
      io.unobserve(e.target);
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  $$(".reveal").forEach((el) => (reduce ? el.classList.add("is-in") : io.observe(el)));

  // ── Saat (menü çubuğu)
  const clock = $("[data-clock]");
  const tick = () => {
    const d = new Date();
    clock.textContent = d.toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" });
  };
  tick();
  setInterval(tick, 20000);

  // ── Kuşlar imlece doğru hafifçe döner (gözü takip eder gibi)
  const birds = $$("[data-eyes]");
  let mx = window.innerWidth / 2, my = 0;
  window.addEventListener("pointermove", (e) => { mx = e.clientX; my = e.clientY; }, { passive: true });
  const follow = () => {
    birds.forEach((b) => {
      const r = b.getBoundingClientRect();
      const dx = (mx - (r.left + r.width / 2)) / window.innerWidth;
      const dy = (my - (r.top + r.height / 2)) / window.innerHeight;
      b.style.setProperty("--tilt", `${Math.max(-12, Math.min(12, dx * 30 + dy * 10))}deg`);
      b.style.rotate = `${Math.max(-12, Math.min(12, dx * 30 + dy * 10))}deg`;
    });
    requestAnimationFrame(follow);
  };
  if (!reduce) requestAnimationFrame(follow);

  // ── Hero: arka plandaki terminale yazı
  const typer = $("[data-typer]");
  async function type(lines) {
    typer.innerHTML = "";
    for (const [prefix, text, delay] of lines) {
      const line = document.createElement("div");
      if (prefix) { const p = document.createElement("span"); p.className = "p"; p.textContent = prefix; line.append(p); }
      const t = document.createTextNode("");
      line.append(t);
      typer.append(line);
      if (reduce) { t.textContent = text; continue; }
      for (const ch of text) { t.textContent += ch; await wait(18 + Math.random() * 30); }
      await wait(delay ?? 300);
    }
  }

  // ── Hero: çentikteki ada senaryosu (sonsuz döngü)
  const island = $("[data-island]");
  const caption = $("[data-caption]");
  const steps = Object.fromEntries($$("[data-step]").map((li) => [li.dataset.step, li]));
  const setStep = (name, cls) => { steps[name].className = cls; };
  const resetSteps = () => Object.values(steps).forEach((li) => (li.className = ""));
  const set = (state, mood, view, text) => {
    island.dataset.state = state;
    island.dataset.mood = mood;
    if (view) island.dataset.view = view;
    if (text) caption.textContent = text;
  };

  async function scenario() {
    for (;;) {
      resetSteps();
      set("collapsed", "idle", null, "Çentikte bekliyor…");
      await type([["› ", "KDV oranını %20 yap ve testleri çalıştır", 600]]);
      set("collapsed", "working", null, "Claude çalışıyor — kuş da.");
      await wait(1600);

      set("open", "working", "diff", "Her düzenleme çentikte, satır satır.");
      setStep("read", "is-done"); setStep("edit", "is-live");
      await wait(2600);
      setStep("edit", "is-done"); setStep("bash", "is-ask");

      set("open", "alert", "ask", "İzin gerekince çentik açılır.");
      await wait(2200);
      const auto = $("[data-auto]");
      auto.classList.add("is-pressed");
      caption.textContent = "Tek dokunuş: oturum Otomatik moda geçti.";
      await wait(650);
      auto.classList.remove("is-pressed");

      setStep("bash", "is-live");
      set("open", "working", "term", "Komut çıktısı canlı akar.");
      await wait(2400);
      setStep("bash", "is-done"); setStep("done", "is-done");

      set("open", "done", "done", "Bitti. Terminal kapalı olsa da buradan devam edersin.");
      await wait(3600);
      set("collapsed", "done", null, "…ve çentiğine geri döner.");
      await wait(2200);
    }
  }
  if (reduce) {
    set("open", "done", "done", "Serçe adası");
    Object.values(steps).forEach((li) => (li.className = "is-done"));
    typer.innerHTML = '<div><span class="p">› </span>KDV oranını %20 yap ve testleri çalıştır</div>';
  } else {
    scenario();
  }

  // ── Nasıl çalışır: kaydırdıkça yapışkan sahne değişir
  const howSteps = $$("[data-how]");
  const howViews = $$("[data-how-view]");
  const activate = (i) => {
    howSteps.forEach((s) => s.classList.toggle("is-active", s.dataset.how === String(i)));
    howViews.forEach((v) => v.classList.toggle("is-active", v.dataset.howView === String(i)));
    if (i === 3) composeLoop();
  };
  activate(0);
  const howIO = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) activate(Number(e.target.dataset.how)); });
  }, { rootMargin: "-45% 0px -45% 0px" });
  howSteps.forEach((s) => howIO.observe(s));

  // Kapanmış oturuma yazılan mesaj (dördüncü adım)
  const compose = $("[data-compose]");
  let composing = false;
  async function composeLoop() {
    if (composing) return;
    composing = true;
    const text = "CHANGELOG'a 2026 notunu da ekle";
    if (reduce) { compose.textContent = text; return; }
    compose.textContent = "";
    for (const ch of text) { compose.textContent += ch; await wait(45); }
    await wait(1400);
    composing = false;
  }

  // ── Bento: imleci izleyen ışık
  $$(".card").forEach((card) => {
    card.addEventListener("pointermove", (e) => {
      const r = card.getBoundingClientRect();
      card.style.setProperty("--mx", `${e.clientX - r.left}px`);
      card.style.setProperty("--my", `${e.clientY - r.top}px`);
    });
  });

  // ── Sayaçlar
  const countIO = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      const el = e.target;
      const target = parseFloat(el.dataset.count);
      const dec = Number(el.dataset.dec || 0);
      countIO.unobserve(el);
      const fmt = (v) => v.toLocaleString("tr-TR", { minimumFractionDigits: dec, maximumFractionDigits: dec });
      if (reduce) { el.textContent = fmt(target); return; }
      const t0 = performance.now();
      const dur = 1200;
      const step = (now) => {
        const p = Math.min(1, (now - t0) / dur);
        const eased = 1 - Math.pow(1 - p, 4);
        el.textContent = fmt(target * eased);
        if (p < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    });
  }, { threshold: 0.6 });
  $$("[data-count]").forEach((el) => countIO.observe(el));

  // ── Footer: "çentikte şu an" sayacı ara sıra değişir
  const sessions = $("[data-sessions]");
  if (!reduce) setInterval(() => { sessions.textContent = String(2 + Math.floor(Math.random() * 3)); }, 7000);
})();
