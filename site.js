(() => {
  const INSTALL = "curl -fsSL https://lidless-mac.vercel.app/install | bash";
  const button = document.getElementById("copy");
  const label = document.getElementById("copy-label");

  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(INSTALL);
      label.textContent = "Copied";
      button.classList.add("is-done");
    } catch {
      label.textContent = "Select it";
      const range = document.createRange();
      range.selectNodeContents(document.getElementById("command"));
      getSelection().removeAllRanges();
      getSelection().addRange(range);
    }
    setTimeout(() => { label.textContent = "Copy"; button.classList.remove("is-done"); }, 1800);
  });
})();
