(() => {
  const panel = document.querySelector("[data-panel]");
  const screen = document.querySelector("[data-screen]");
  const statusItem = document.querySelector("[data-status-item]");
  const statusLabel = document.querySelector("[data-status-label]");
  const tabButtons = document.querySelectorAll("[data-tab]");
  const themeButtons = document.querySelectorAll("[data-theme]");

  const screens = {
    accounts: { height: 416, alt: "The Accounts tab: the active account with rings for its 5-hour and weekly limits, and a second account ready to switch to" },
    resets: { height: 596, alt: "The Resets tab: five reset credits across two accounts, the next expiring in five days" },
    settings: { height: 530, alt: "The Settings tab with menu bar options and automation switches" }
  };
  let tab = "accounts";
  let theme = "dark";

  for (const name of Object.keys(screens)) {
    for (const mode of ["dark", "light"]) {
      const image = new Image();
      image.src = `assets/screens/${name}-${mode}.webp`;
    }
  }

  const setPressed = (buttons, attribute, value) => {
    buttons.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset[attribute] === value)));
  };

  let screenTransition;
  const showScreen = () => {
    if (!screen || !panel) return;
    window.clearTimeout(screenTransition);
    const next = `assets/screens/${tab}-${theme}.webp`;
    const selected = screens[tab];
    if (screen.getAttribute("src") === next) {
      panel.classList.remove("is-swapping");
      return;
    }
    panel.classList.add("is-swapping");
    screenTransition = window.setTimeout(() => {
      screen.src = next;
      screen.height = selected.height;
      screen.alt = selected.alt;
      panel.classList.remove("is-swapping");
    }, 120);
  };

  const setOpen = (open) => {
    if (!panel || !statusItem) return;
    panel.classList.toggle("is-closed", !open);
    statusItem.setAttribute("aria-expanded", String(open));
    if (statusLabel) statusLabel.textContent = open ? "Hide the account panel" : "Show the account panel";
  };

  tabButtons.forEach((button) => button.addEventListener("click", () => {
    tab = button.dataset.tab;
    setPressed(tabButtons, "tab", tab);
    setOpen(true);
    showScreen();
  }));

  themeButtons.forEach((button) => button.addEventListener("click", () => {
    theme = button.dataset.theme;
    setPressed(themeButtons, "theme", theme);
    setOpen(true);
    showScreen();
  }));

  statusItem?.addEventListener("click", () => {
    const hero = document.querySelector(".hero");
    const isOpen = statusItem.getAttribute("aria-expanded") === "true";
    if (hero && hero.getBoundingClientRect().bottom < 120) {
      setOpen(true);
      hero.scrollIntoView({ behavior: "smooth" });
      return;
    }
    setOpen(!isOpen);
  });

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const source = document.querySelector(button.dataset.copy);
      if (!source) return;
      try {
        await navigator.clipboard.writeText(source.textContent.trim());
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select and copy";
      }
      window.setTimeout(() => { button.textContent = "Copy"; }, 1800);
    });
  });

  requestAnimationFrame(() => document.documentElement.classList.add("page-loaded"));
})();
