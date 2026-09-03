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
    const rect = anchor.getBoundingClientRect();
    dropdown.style.position = "fixed";
    dropdown.style.top = (rect.bottom + 4) + "px";
    dropdown.style.left = rect.left + "px";
    dropdown.style.width = rect.width + "px";
    dropdown.style.right = "auto";
    dropdown.style.zIndex = "9999";
  }

  function resetPosition(dropdown) {
    dropdown.style.position = "";
    dropdown.style.top = "";
    dropdown.style.left = "";
    dropdown.style.width = "";
    dropdown.style.right = "";
    dropdown.style.zIndex = "";
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
        if (opts.portal) {
          positionFixed(dropdown, anchor);
          document.body.appendChild(dropdown);
        }
        dropdown.classList.add("open");
        trigger.classList.add("open");
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
