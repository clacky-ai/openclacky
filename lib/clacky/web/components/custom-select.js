// Generic single-choice dropdown shared by settings/onboard.
// DOM contract:
//   wrapper > .custom-select-trigger > .custom-select-value (+ .custom-select-arrow)
//          + .custom-select-dropdown > .custom-select-option[data-value][data-label]
// Business code owns the option markup (populate); this module owns the
// open/close/selection mechanics so every dropdown behaves identically.
window.CustomSelect = (function () {
  "use strict";

  const instances = [];
  let globalBound = false;

  function bindGlobalClose() {
    if (globalBound) return;
    globalBound = true;
    document.addEventListener("click", () => {
      for (let i = instances.length - 1; i >= 0; i--) {
        const inst = instances[i];
        if (!inst._trigger.isConnected) { instances.splice(i, 1); continue; }
        inst.close();
      }
    });
  }

  function positionFixed(dropdown, anchor) {
    // min-width:100% resolves against the viewport once position:fixed,
    // so pin it to the anchor width; leave width to the CSS max-content
    // rule so narrow triggers (search type filter) still fit their options.
    dropdown.style.minWidth = anchor.getBoundingClientRect().width + "px";
    FloatingDropdown.place(dropdown, anchor);
  }

  function resetPosition(dropdown) {
    FloatingDropdown.reset(dropdown);
  }

  // A portalled panel lives under <body> with position:fixed, so it keeps its
  // viewport coordinates while its anchor scrolls away. Re-place every open
  // panel on scroll/resize to keep it attached to the trigger.
  let trackingBound = false;
  let rafPending = false;

  function bindTracking() {
    if (trackingBound) return;
    trackingBound = true;
    const reposition = () => {
      if (rafPending) return;
      rafPending = true;
      requestAnimationFrame(() => {
        rafPending = false;
        instances.forEach((inst) => inst._trackPosition());
      });
    };
    // Scroll events do not bubble, so capture is the only way to hear inner
    // scroll containers (the settings panel scrolls in #settings-body)
    // instead of just the window.
    window.addEventListener("scroll", reposition, true);
    window.addEventListener("resize", reposition);
  }

  function init(opts) {
    const trigger = opts.trigger;
    const dropdown = opts.dropdown;
    const valueSpan = trigger.querySelector(".custom-select-value");
    const home = dropdown.parentElement;
    const anchor = opts.anchor || home;
    const placeholderText = valueSpan ? valueSpan.textContent.trim() : "";
    const selectedOption = dropdown.querySelector(".custom-select-option.selected");

    const instance = {
      _trigger: trigger,
      value: selectedOption ? (selectedOption.dataset.value || "") : "",
      open: function () {
        instances.forEach(function (other) {
          if (other !== instance) other.close();
        });
        if (opts.portal) document.body.appendChild(dropdown);
        dropdown.classList.add("open");
        trigger.classList.add("open");
        // Position after the panel is rendered, otherwise scrollHeight is 0
        // and the "open upwards" decision is blind.
        if (opts.portal) {
          bindTracking();
          positionFixed(dropdown, anchor);
        }
      },
      _trackPosition: function () {
        if (!opts.portal || !dropdown.classList.contains("open")) return;
        if (!trigger.isConnected) return;
        const rect = anchor.getBoundingClientRect();
        // Anchor scrolled fully out of view: a fixed panel pinned to it would
        // collapse against the viewport edge, so close instead of floating
        // detached from the field it edits.
        if (rect.bottom < 0 || rect.top > window.innerHeight) {
          instance.close();
          return;
        }
        positionFixed(dropdown, anchor);
      },
      close: function () {
        if (!dropdown.classList.contains("open")) return;
        dropdown.classList.remove("open");
        trigger.classList.remove("open");
        if (opts.portal && home) {
          resetPosition(dropdown);
          home.appendChild(dropdown);
        }
      },
      setValue: function (value, text) {
        if (valueSpan) {
          let label = text;
          if (typeof label !== "string") {
            const opt = dropdown.querySelector('.custom-select-option[data-value="' + value + '"]');
            label = opt ? (opt.dataset.label || opt.textContent.trim()) : "";
          }
          if (!value && !label) label = placeholderText;
          valueSpan.textContent = label;
          valueSpan.classList.toggle("placeholder", !value);
        }
        dropdown.querySelectorAll(".custom-select-option").forEach(function (opt) {
          opt.classList.toggle("selected", opt.dataset.value === value);
        });
        instance.value = value;
      }
    };

    trigger.addEventListener("click", function (e) {
      e.stopPropagation();
      if (dropdown.classList.contains("open")) {
        instance.close();
      } else {
        instance.open();
      }
    });

    trigger.addEventListener("keydown", function (e) {
      if (e.key !== "Enter" && e.key !== " ") return;
      e.preventDefault();
      e.stopPropagation();
      if (dropdown.classList.contains("open")) {
        instance.close();
      } else {
        instance.open();
      }
    });

    dropdown.addEventListener("click", function (e) {
      const option = e.target.closest(".custom-select-option");
      if (!option) return;
      e.stopPropagation();
      const value = option.dataset.value || "";
      const text = option.dataset.label || option.textContent.trim();
      instance.setValue(value, text);
      instance.close();
      if (typeof opts.onSelect === "function") opts.onSelect(value, text, option);
    });

    instances.push(instance);
    dropdown.__customSelect = instance;
    bindGlobalClose();
    return instance;
  }

  return { init: init };
})();
