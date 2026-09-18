// ── ModelPicker — shared model dropdown component ─────────────────────────
// Renders the model list (vendor badge, price ratio, vision/remark/sub
// decorations, latency cell, sub-model toggle) plus the sub-model variant
// panel, benchmark button and generation footer. Session-specific actions
// (switching card/sub-model, running the benchmark request, opening media
// config) are injected as callbacks so the same component powers both the
// session info bar and the #new landing page.
const ModelPicker = (() => {
  // Price-ratio badges for the submodel rows. Ratios come from
  // GET /api/model_prices (backed by Clacky::ModelPricing), so the local
  // pricing table stays the single source of truth - no hardcoded JS prices.
  const _priceCache = new Map(); // model name -> { in, out, label } | null

  function _fmtRatio(ratio) {
    if (ratio >= 10) return Math.round(ratio) + "x";
    const s = ratio >= 1 ? ratio.toFixed(1) : ratio.toFixed(2);
    return s.replace(/\.?0+$/, "") + "x";
  }

  // Cache of the most recent benchmark results, keyed by model_id. Kept at
  // closure scope so the numbers survive closing & reopening the dropdown.
  let _benchCache = {};        // { [model_id]: { ttft_ms, ok, error, ts } }
  let _benchInFlight = false;  // prevent double-click spam

  // Vendor badge: tile with the provider's mark, shown before each model name.
  // Model family wins over provider prefix ("or-gemini-…" matches Gemini before
  // the "or-" OpenRouter rule). `svg` marks are monochrome and inherit the
  // tile's white ink; `brandSvg` keeps the official multi-color/gradient
  // artwork, so those tiles take a light background and skip the currentColor
  // fill. Unknown models fall back to their initial on a neutral tile.
  const _VENDOR_RULES = [
    { re: /claude|anthropic/i,   label: "A", color: "#fff",
      brandSvg: '<path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z" fill="#D97757" fill-rule="nonzero"/>' },
    { re: /deepseek/i,           label: "D", color: "#4D6BFE", viewBox: "0 1.5 27 20.5",
      svg: '<path d="M26.5174 3.39471C26.235 3.2567 26.1137 3.52006 25.9487 3.65346C25.8923 3.69659 25.8446 3.75294 25.7969 3.80469C25.3846 4.24516 24.9027 4.53439 24.2737 4.49989C23.3536 4.44814 22.5682 4.73737 21.8735 5.44119C21.7258 4.57349 21.2353 4.0554 20.4889 3.72304C20.0985 3.55054 19.7034 3.37746 19.4297 3.00197C19.2388 2.73459 19.1865 2.43673 19.091 2.14289C19.0301 1.96579 18.9697 1.78466 18.7656 1.75418C18.5442 1.71968 18.4574 1.90541 18.3705 2.06067C18.0232 2.69549 17.8887 3.39471 17.9019 4.10313C17.9324 5.6965 18.6051 6.96556 19.9421 7.86834C20.0939 7.97184 20.133 8.07535 20.0852 8.22658C19.9938 8.53766 19.8857 8.83955 19.7903 9.15063C19.7293 9.34901 19.6384 9.39271 19.4257 9.30588C18.692 8.9994 18.0583 8.54571 17.4982 7.99772C16.5477 7.07827 15.6881 6.06336 14.6162 5.26869C14.3644 5.08296 14.1125 4.91045 13.8521 4.746C12.7584 3.68394 13.9952 2.81164 14.2816 2.70814C14.5812 2.60003 14.3857 2.22857 13.4179 2.23317C12.4502 2.2372 11.5646 2.56151 10.4359 2.99335C10.2708 3.05832 10.0972 3.10547 9.91951 3.14457C8.8954 2.95022 7.83162 2.90709 6.72069 3.03245C4.62877 3.26533 2.95777 4.25436 1.72954 5.94261C0.254043 7.97184 -0.0932678 10.2777 0.33167 12.6824C0.778458 15.2171 2.07225 17.3153 4.06008 18.9558C6.12152 20.6567 8.49577 21.4905 11.2047 21.3306C12.8498 21.2358 14.6812 21.0155 16.7473 19.2669C17.2682 19.5262 17.8151 19.6297 18.7219 19.7074C19.4205 19.7723 20.0933 19.6729 20.6143 19.5648C21.4302 19.3923 21.3739 18.6367 21.0789 18.4981C18.6874 17.3843 19.2124 17.8374 18.7351 17.4706C19.9501 16.033 21.8063 13.4776 22.379 9.99821C22.4353 9.61409 22.5072 9.073 22.4986 8.76192C22.494 8.57216 22.5377 8.49856 22.7545 8.47671C23.3536 8.40771 23.935 8.24383 24.4692 7.94999C26.0188 7.10357 26.6439 5.71318 26.7911 4.04678C26.8129 3.79204 26.7865 3.52869 26.5174 3.39471ZM13.0143 18.3946C10.6964 16.5724 9.5722 15.9726 9.10816 15.9985C8.67402 16.0244 8.75222 16.5212 8.84768 16.8449C8.94773 17.1646 9.07768 17.3849 9.25996 17.6655C9.38589 17.8512 9.47272 18.1272 9.13404 18.3348C8.38766 18.7965 7.08985 18.1796 7.0289 18.1491C5.51833 17.2595 4.25559 16.0853 3.36546 14.4793C2.50581 12.9337 2.0067 11.2753 1.92447 9.50542C1.90262 9.07818 2.02855 8.92695 2.45406 8.84932C3.01413 8.74582 3.59144 8.72397 4.15093 8.80619C6.51656 9.15178 8.53027 10.2092 10.2185 11.8848C11.1822 12.8388 11.9114 13.979 12.6623 15.0929C13.461 16.2757 14.3201 17.4027 15.4144 18.3268C15.8008 18.6505 16.109 18.8966 16.404 19.0783C15.5144 19.1778 14.0297 19.1991 13.0143 18.3958V18.3946ZM14.1252 11.2489C14.1252 11.0591 14.277 10.9079 14.4679 10.9079C14.511 10.9079 14.5501 10.9165 14.5852 10.9292C14.6329 10.9464 14.6766 10.9723 14.7111 11.0114C14.7721 11.0718 14.8066 11.158 14.8066 11.2489C14.8066 11.4386 14.6548 11.5899 14.4639 11.5899C14.273 11.5899 14.1252 11.4386 14.1252 11.2489ZM17.5759 13.0188C17.3545 13.1096 17.1331 13.1873 16.9203 13.1959C16.5903 13.2131 16.2303 13.0791 16.0348 12.9153C15.7312 12.6605 15.5139 12.5179 15.423 12.0734C15.3839 11.8837 15.4057 11.5899 15.4402 11.4214C15.5185 11.0585 15.4316 10.8257 15.1757 10.614C14.9676 10.4415 14.7025 10.3938 14.4115 10.3938C14.3029 10.3938 14.2034 10.3461 14.1292 10.3076C14.0079 10.2472 13.9078 10.096 14.0033 9.91023C14.0338 9.84985 14.1815 9.70322 14.216 9.67734C14.6111 9.45251 15.0665 9.52612 15.488 9.6946C15.8784 9.85445 16.174 10.1477 16.5989 10.5623C17.033 11.0631 17.1112 11.2011 17.3585 11.5772C17.554 11.871 17.7317 12.1729 17.8536 12.5185C17.9272 12.7341 17.8317 12.9107 17.5759 13.0188Z"/>' },
    { re: /glm|zhipu|bigmodel/i, label: "Z", color: "#131212", viewBox: "0 0 32 27",
      svg: '<path d="M16.5376 0.0307374L14.3326 3.13223C14.1617 3.37577 13.9331 3.57415 13.6667 3.71001C13.4004 3.84586 13.1045 3.91504 12.8048 3.9115H0.787598V0.015152H16.5376V0.0307374Z"/><path d="M31.5 0.0321655L12.6 26.5273H0L18.9 0.0321655H31.5Z"/><path d="M14.9624 26.5272L17.1832 23.4101C17.3564 23.1689 17.5856 22.9723 17.8513 22.8368C18.1171 22.7012 18.4119 22.6306 18.7109 22.6308H30.7124V26.5272H14.9624Z"/>' },
    { re: /gemini/i,             label: "G", color: "#fff",
      brandSvg: '<path d="M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z" fill="#3186FF"/><path d="M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z" fill="url(#lobe-icons-gemini-0-_R_0_)"/><path d="M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z" fill="url(#lobe-icons-gemini-1-_R_0_)"/><path d="M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z" fill="url(#lobe-icons-gemini-2-_R_0_)"/><defs><linearGradient gradientUnits="userSpaceOnUse" id="lobe-icons-gemini-0-_R_0_" x1="7" x2="11" y1="15.5" y2="12"><stop stop-color="#08B962"/><stop offset="1" stop-color="#08B962" stop-opacity="0"/></linearGradient><linearGradient gradientUnits="userSpaceOnUse" id="lobe-icons-gemini-1-_R_0_" x1="8" x2="11.5" y1="5.5" y2="11"><stop stop-color="#F94543"/><stop offset="1" stop-color="#F94543" stop-opacity="0"/></linearGradient><linearGradient gradientUnits="userSpaceOnUse" id="lobe-icons-gemini-2-_R_0_" x1="3.5" x2="17.5" y1="13.5" y2="12"><stop stop-color="#FABC12"/><stop offset=".46" stop-color="#FABC12" stop-opacity="0"/></linearGradient></defs>' },
    { re: /gpt|openai/i,         label: "G", color: "#000",
      svg: '<path d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"/>' },
    { re: /minimax/i,            label: "M", color: "#fff",
      brandSvg: '<defs><linearGradient id="lobe-icons-minimax-_R_0_" x1="0%" x2="100.182%" y1="50.057%" y2="50.057%"><stop offset="0%" stop-color="#E2167E"/><stop offset="100%" stop-color="#FE603C"/></linearGradient></defs><path d="M16.278 2c1.156 0 2.093.927 2.093 2.07v12.501a.74.74 0 00.744.709.74.74 0 00.743-.709V9.099a2.06 2.06 0 012.071-2.049A2.06 2.06 0 0124 9.1v6.561a.649.649 0 01-.652.645.649.649 0 01-.653-.645V9.1a.762.762 0 00-.766-.758.762.762 0 00-.766.758v7.472a2.037 2.037 0 01-2.048 2.026 2.037 2.037 0 01-2.048-2.026v-12.5a.785.785 0 00-.788-.753.785.785 0 00-.789.752l-.001 15.904A2.037 2.037 0 0113.441 22a2.037 2.037 0 01-2.048-2.026V18.04c0-.356.292-.645.652-.645.36 0 .652.289.652.645v1.934c0 .263.142.506.372.638.23.131.514.131.744 0a.734.734 0 00.372-.638V4.07c0-1.143.937-2.07 2.093-2.07zm-5.674 0c1.156 0 2.093.927 2.093 2.07v11.523a.648.648 0 01-.652.645.648.648 0 01-.652-.645V4.07a.785.785 0 00-.789-.78.785.785 0 00-.789.78v14.013a2.06 2.06 0 01-2.07 2.048 2.06 2.06 0 01-2.071-2.048V9.1a.762.762 0 00-.766-.758.762.762 0 00-.766.758v3.8a2.06 2.06 0 01-2.071 2.049A2.06 2.06 0 010 12.9v-1.378c0-.357.292-.646.652-.646.36 0 .653.29.653.646V12.9c0 .418.343.757.766.757s.766-.339.766-.757V9.099a2.06 2.06 0 012.07-2.048 2.06 2.06 0 012.071 2.048v8.984c0 .419.343.758.767.758.423 0 .766-.339.766-.758V4.07c0-1.143.937-2.07 2.093-2.07z" fill="url(#lobe-icons-minimax-_R_0_)" fill-rule="nonzero"/>' },
    { re: /qwen|tongyi/i,        label: "Q", color: "#fff",
      brandSvg: '<path d="M12.604 1.34c.393.69.784 1.382 1.174 2.075a.18.18 0 00.157.091h5.552c.174 0 .322.11.446.327l1.454 2.57c.19.337.24.478.024.837-.26.43-.513.864-.76 1.3l-.367.658c-.106.196-.223.28-.04.512l2.652 4.637c.172.301.111.494-.043.77-.437.785-.882 1.564-1.335 2.34-.159.272-.352.375-.68.37-.777-.016-1.552-.01-2.327.016a.099.099 0 00-.081.05 575.097 575.097 0 01-2.705 4.74c-.169.293-.38.363-.725.364-.997.003-2.002.004-3.017.002a.537.537 0 01-.465-.271l-1.335-2.323a.09.09 0 00-.083-.049H4.982c-.285.03-.553-.001-.805-.092l-1.603-2.77a.543.543 0 01-.002-.54l1.207-2.12a.198.198 0 000-.197 550.951 550.951 0 01-1.875-3.272l-.79-1.395c-.16-.31-.173-.496.095-.965.465-.813.927-1.625 1.387-2.436.132-.234.304-.334.584-.335a338.3 338.3 0 012.589-.001.124.124 0 00.107-.063l2.806-4.895a.488.488 0 01.422-.246c.524-.001 1.053 0 1.583-.006L11.704 1c.341-.003.724.032.9.34zm-3.432.403a.06.06 0 00-.052.03L6.254 6.788a.157.157 0 01-.135.078H3.253c-.056 0-.07.025-.041.074l5.81 10.156c.025.042.013.062-.034.063l-2.795.015a.218.218 0 00-.2.116l-1.32 2.31c-.044.078-.021.118.068.118l5.716.008c.046 0 .08.02.104.061l1.403 2.454c.046.081.092.082.139 0l5.006-8.76.783-1.382a.055.055 0 01.096 0l1.424 2.53a.122.122 0 00.107.062l2.763-.02a.04.04 0 00.035-.02.041.041 0 000-.04l-2.9-5.086a.108.108 0 010-.113l.293-.507 1.12-1.977c.024-.041.012-.062-.035-.062H9.2c-.059 0-.073-.026-.043-.077l1.434-2.505a.107.107 0 000-.114L9.225 1.774a.06.06 0 00-.053-.031zm6.29 8.02c.046 0 .058.02.034.06l-.832 1.465-2.613 4.585a.056.056 0 01-.05.029.058.058 0 01-.05-.029L8.498 9.841c-.02-.034-.01-.052.028-.054l.216-.012 6.722-.012z" fill="url(#lobe-icons-qwen-_R_0_)" fill-rule="nonzero"/><defs><linearGradient id="lobe-icons-qwen-_R_0_" x1="0%" x2="100%" y1="0%" y2="0%"><stop offset="0%" stop-color="#6336E7" stop-opacity=".84"/><stop offset="100%" stop-color="#6F69F7" stop-opacity=".84"/></linearGradient></defs>' },
    { re: /kimi|moonshot/i,      label: "K", color: "#111827",
      brandSvg: '<path d="M21.846 0a1.923 1.923 0 110 3.846H20.15a.226.226 0 01-.227-.226V1.923C19.923.861 20.784 0 21.846 0z" fill="#1783FF"/><path d="M11.065 11.199l7.257-7.2c.137-.136.06-.41-.116-.41H14.3a.164.164 0 00-.117.051l-7.82 7.756c-.122.12-.302.013-.302-.179V3.82c0-.127-.083-.23-.185-.23H3.186c-.103 0-.186.103-.186.23V19.77c0 .128.083.23.186.23h2.69c.103 0 .186-.102.186-.23v-3.25c0-.069.025-.135.069-.178l2.424-2.406a.158.158 0 01.205-.023l6.484 4.772a7.677 7.677 0 003.453 1.283c.108.012.2-.095.2-.23v-3.06c0-.117-.07-.212-.164-.227a5.028 5.028 0 01-2.027-.807l-5.613-4.064c-.117-.078-.132-.279-.028-.381z" fill="#fff"/>' },
    { re: /grok|xai/i,           label: "X", color: "#111827",
      svg: '<path d="M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"/>' },
    { re: /doubao/i,             label: "D", color: "#fff",
      brandSvg: '<path d="M5.31 15.756c.172-3.75 1.883-5.999 2.549-6.739-3.26 2.058-5.425 5.658-6.358 8.308v1.12C1.501 21.513 4.226 24 7.59 24a6.59 6.59 0 002.2-.375c.353-.12.7-.248 1.039-.378.913-.899 1.65-1.91 2.243-2.992-4.877 2.431-7.974.072-7.763-4.5l.002.001z" fill="#1E37FC"/><path d="M22.57 10.283c-1.212-.901-4.109-2.404-7.397-2.8.295 3.792.093 8.766-2.1 12.773a12.782 12.782 0 01-2.244 2.992c3.764-1.448 6.746-3.457 8.596-5.219 2.82-2.683 3.353-5.178 3.361-6.66a2.737 2.737 0 00-.216-1.084v-.002z" fill="#37E1BE"/><path d="M14.303 1.867C12.955.7 11.248 0 9.39 0 7.532 0 5.883.677 4.545 1.807 2.791 3.29 1.627 5.557 1.5 8.125v9.201c.932-2.65 3.097-6.25 6.357-8.307.5-.318 1.025-.595 1.569-.829 1.883-.801 3.878-.932 5.746-.706-.222-2.83-.718-5.002-.87-5.617h.001z" fill="#A569FF"/><path d="M17.305 4.961a199.47 199.47 0 01-1.08-1.094c-.202-.213-.398-.419-.586-.622l-1.333-1.378c.151.615.648 2.786.869 5.617 3.288.395 6.185 1.898 7.396 2.8-1.306-1.275-3.475-3.487-5.266-5.323z" fill="#1E37FC"/>' },
    { re: /ark|volces/i,         label: "V", color: "#fff",
      brandSvg: '<path d="M19.44 10.153l-2.936 11.586a.215.215 0 00.214.261h5.87a.215.215 0 00.214-.261l-2.95-11.586a.214.214 0 00-.412 0zM3.28 12.778l-2.275 8.96A.214.214 0 001.22 22h4.532a.212.212 0 00.214-.165.214.214 0 000-.097l-2.276-8.96a.214.214 0 00-.41 0z" fill="#00E5E5"/><path d="M7.29 5.359L3.148 21.738a.215.215 0 00.203.261h8.29a.214.214 0 00.215-.261L7.7 5.358a.214.214 0 00-.41 0z" fill="#006EFF"/><path d="M14.44.15a.214.214 0 00-.41 0L8.366 21.739a.214.214 0 00.214.261H19.9a.216.216 0 00.171-.078.214.214 0 00.044-.183L14.439.15z" fill="#006EFF"/><path d="M10.278 7.741L6.685 21.736a.214.214 0 00.214.264h7.17a.215.215 0 00.214-.264L10.688 7.741a.214.214 0 00-.41 0z" fill="#00E5E5"/>' },
    { re: /llama/i,              label: "L", color: "#fff", ink: "#111827",
      svg: '<path d="M7.905 1.09c.216.085.411.225.588.41.295.306.544.744.734 1.263.191.522.315 1.1.362 1.68a5.054 5.054 0 012.049-.636l.051-.004c.87-.07 1.73.087 2.48.474.101.053.2.11.297.17.05-.569.172-1.134.36-1.644.19-.52.439-.957.733-1.264a1.67 1.67 0 01.589-.41c.257-.1.53-.118.796-.042.401.114.745.368 1.016.737.248.337.434.769.561 1.287.23.934.27 2.163.115 3.645l.053.04.026.019c.757.576 1.284 1.397 1.563 2.35.435 1.487.216 3.155-.534 4.088l-.018.021.002.003c.417.762.67 1.567.724 2.4l.002.03c.064 1.065-.2 2.137-.814 3.19l-.007.01.01.024c.472 1.157.62 2.322.438 3.486l-.006.039a.651.651 0 01-.747.536.648.648 0 01-.54-.742c.167-1.033.01-2.069-.48-3.123a.643.643 0 01.04-.617l.004-.006c.604-.924.854-1.83.8-2.72-.046-.779-.325-1.544-.8-2.273a.644.644 0 01.18-.886l.009-.006c.243-.159.467-.565.58-1.12a4.229 4.229 0 00-.095-1.974c-.205-.7-.58-1.284-1.105-1.683-.595-.454-1.383-.673-2.38-.61a.653.653 0 01-.632-.371c-.314-.665-.772-1.141-1.343-1.436a3.288 3.288 0 00-1.772-.332c-1.245.099-2.343.801-2.67 1.686a.652.652 0 01-.61.425c-1.067.002-1.893.252-2.497.703-.522.39-.878.935-1.066 1.588a4.07 4.07 0 00-.068 1.886c.112.558.331 1.02.582 1.269l.008.007c.212.207.257.53.109.785-.36.622-.629 1.549-.673 2.44-.05 1.018.186 1.902.719 2.536l.016.019a.643.643 0 01.095.69c-.576 1.236-.753 2.252-.562 3.052a.652.652 0 01-1.269.298c-.243-1.018-.078-2.184.473-3.498l.014-.035-.008-.012a4.339 4.339 0 01-.598-1.309l-.005-.019a5.764 5.764 0 01-.177-1.785c.044-.91.278-1.842.622-2.59l.012-.026-.002-.002c-.293-.418-.51-.953-.63-1.545l-.005-.024a5.352 5.352 0 01.093-2.49c.262-.915.777-1.701 1.536-2.269.06-.045.123-.09.186-.132-.159-1.493-.119-2.73.112-3.67.127-.518.314-.95.562-1.287.27-.368.614-.622 1.015-.737.266-.076.54-.059.797.042zm4.116 9.09c.936 0 1.8.313 2.446.855.63.527 1.005 1.235 1.005 1.94 0 .888-.406 1.58-1.133 2.022-.62.375-1.451.557-2.403.557-1.009 0-1.871-.259-2.493-.734-.617-.47-.963-1.13-.963-1.845 0-.707.398-1.417 1.056-1.946.668-.537 1.55-.849 2.485-.849zm0 .896a3.07 3.07 0 00-1.916.65c-.461.37-.722.835-.722 1.25 0 .428.21.829.61 1.134.455.347 1.124.548 1.943.548.799 0 1.473-.147 1.932-.426.463-.28.7-.686.7-1.257 0-.423-.246-.89-.683-1.256-.484-.405-1.14-.643-1.864-.643zm.662 1.21l.004.004c.12.151.095.37-.056.49l-.292.23v.446a.375.375 0 01-.376.373.375.375 0 01-.376-.373v-.46l-.271-.218a.347.347 0 01-.052-.49.353.353 0 01.494-.051l.215.172.22-.174a.353.353 0 01.49.051zm-5.04-1.919c.478 0 .867.39.867.871a.87.87 0 01-.868.871.87.87 0 01-.867-.87.87.87 0 01.867-.872zm8.706 0c.48 0 .868.39.868.871a.87.87 0 01-.868.871.87.87 0 01-.867-.87.87.87 0 01.867-.872zM7.44 2.3l-.003.002a.659.659 0 00-.285.238l-.005.006c-.138.189-.258.467-.348.832-.17.692-.216 1.631-.124 2.782.43-.128.899-.208 1.404-.237l.01-.001.019-.034c.046-.082.095-.161.148-.239.123-.771.022-1.692-.253-2.444-.134-.364-.297-.65-.453-.813a.628.628 0 00-.107-.09L7.44 2.3zm9.174.04l-.002.001a.628.628 0 00-.107.09c-.156.163-.32.45-.453.814-.29.794-.387 1.776-.23 2.572l.058.097.008.014h.03a5.184 5.184 0 011.466.212c.086-1.124.038-2.043-.128-2.722-.09-.365-.21-.643-.349-.832l-.004-.006a.659.659 0 00-.285-.239h-.004z"/>' },
    { re: /mistral/i,            label: "M", color: "#F26B1D",
      svg: '<path d="M17.143 3.429v3.428h-3.429v3.429h-3.428V6.857H6.857V3.43H3.43v13.714H0v3.428h10.286v-3.428H6.857v-3.429h3.429v3.429h3.429v-3.429h3.428v3.429h-3.428v3.428H24v-3.428h-3.43V3.429z"/>' },
    { re: /hunyuan/i,            label: "H", color: "#fff",
      brandSvg: '<circle cx="12" cy="12" fill="#0055E9" r="12"/><path d="M12 0c.518 0 1.028.033 1.528.096A6.188 6.188 0 0112.12 12.28l-.12.001c-2.99 0-5.242 2.179-5.554 5.11-.223 2.086.353 4.412 2.242 6.146C3.672 22.1 0 17.479 0 12 0 5.373 5.373 0 12 0z" fill="#A8DFF5"/><path d="M5.286 5a2.438 2.438 0 01.682 3.38c-3.962 5.966-3.215 10.743 2.648 15.136C3.636 22.056 0 17.452 0 12c0-1.787.39-3.482 1.09-5.006.253-.435.525-.872.817-1.311A2.438 2.438 0 015.286 5z" fill="#0055E9"/><path d="M12.98.04c.272.021.543.053.81.093.583.106 1.117.254 1.538.44 6.638 2.927 8.07 10.052 1.748 15.642a4.125 4.125 0 01-5.822-.358c-1.51-1.706-1.3-4.184.357-5.822.858-.848 3.108-1.223 4.045-2.441 1.257-1.634 2.122-6.009-2.523-7.506L12.98.039z" fill="#00BCFF"/><path d="M13.528.096A6.187 6.187 0 0112 12.281a5.75 5.75 0 00-1.71.255c.147-.905.595-1.784 1.321-2.501.858-.848 3.108-1.223 4.045-2.441 1.27-1.651 2.14-6.104-2.676-7.554.184.014.367.033.548.056z" fill="#ECECEE"/>' },
    { re: /ernie|wenxin/i,       label: "E", color: "#fff",
      brandSvg: '<path d="M11.32 1.176a1.4 1.4 0 011.36 0l8.64 4.843c.421.234.68.67.68 1.141v9.68c0 .472-.259.908-.68 1.143l-8.64 4.84a1.4 1.4 0 01-1.36 0l-8.64-4.84A1.31 1.31 0 012 16.84V7.159c0-.471.259-.907.68-1.142l8.64-4.84zm7.42 13.839V8.227L12.002 12 12 19.551l6.059-3.394a1.31 1.31 0 00.68-1.142zM12.68 4.833a1.393 1.393 0 00-1.36 0L5.944 7.846c-.421.235-.68.67-.68 1.142v6.027c0 .47.259.905.68 1.142l2.795 1.566V11.09a1.546 1.546 0 00.221.79 1.527 1.527 0 01-.216-.834l.004-.094.02-.15.018-.084.017-.062.039-.117.062-.142.035-.065.081-.13.094-.122.084-.091.08-.075.125-.1.071-.048.134-.076 5.87-3.29-2.796-1.566z" fill="url(#lobe-icons-wenxin-_R_0_)"/><path d="M12 11.088c0-.875-.73-1.584-1.631-1.584a1.66 1.66 0 00-.855.237c-.027.016-.055.033-.08.05a2.361 2.361 0 00-.123.093c-.022.02-.045.038-.066.059l-.048.045-.063.067c-.014.016-.028.031-.04.048a2.303 2.303 0 00-.094.125l-.042.069a1.7 1.7 0 00-.07.13l-.036.081a.764.764 0 00-.022.06c-.01.03-.02.058-.028.087l-.017.062a.883.883 0 00-.03.16c-.002.025-.007.05-.008.074a1.527 1.527 0 00.213.929c.302.508.85.792 1.414.792.277 0 .558-.068.814-.212l.815-.457v-.914L12 11.088z" fill="#012F8D"/><defs><linearGradient id="lobe-icons-wenxin-_R_0_" x1="9.155%" x2="90.531%" y1="75.177%" y2="25.028%"><stop offset="0%" stop-color="#0A51C3"/><stop offset="100%" stop-color="#23A4FB"/></linearGradient></defs>' },
    { re: /^or-|openrouter/i,    label: "R", color: "#111827",
      svg: '<path d="M18.654 3.87a5.087 5.087 0 110 10.174L23.7 19.09c.64.641.187 1.737-.72 1.737H8.48a8.479 8.479 0 010-16.958h10.175zM8.479 7.26a5.087 5.087 0 100 10.176 5.087 5.087 0 000-10.175z"/>' },
  ];

  // Gradient/clipPath ids inside brand artwork are document-global, so the same
  // mark rendered twice would make every copy resolve to the first one's defs.
  let _brandSeq = 0;

  function vendorBadge(name) {
    const s = String(name || "").trim();
    const rule = _VENDOR_RULES.find(r => r.re.test(s));
    const el = document.createElement("span");
    el.className = "sib-vendor-badge";
    el.style.setProperty("--vendor-color", rule ? rule.color : "#7A8B99");
    if (rule && rule.ink) el.style.color = rule.ink;
    if (rule && rule.color === "#fff") el.classList.add("is-light");
    if (rule && rule.brandSvg) {
      el.classList.add("is-brand");
      let art = rule.brandSvg;
      const seq = ++_brandSeq;
      (art.match(/id="([^"]+)"/g) || []).forEach(attr => {
        const id = attr.slice(4, -1);
        const scoped = id + "-b" + seq;
        art = art.split('id="' + id + '"').join('id="' + scoped + '"')
                 .split("url(#" + id + ")").join("url(#" + scoped + ")");
      });
      el.innerHTML = '<svg viewBox="' + (rule.viewBox || "0 0 24 24") + '" aria-hidden="true">' + art + '</svg>';
    } else if (rule && rule.svg) {
      el.innerHTML = '<svg viewBox="' + (rule.viewBox || "0 0 24 24") + '" aria-hidden="true">' + rule.svg + '</svg>';
    } else {
      el.textContent = rule ? rule.label : (s.charAt(0).toUpperCase() || "?");
    }
    return el;
  }

  // Disclosure caret shared by the clickable status-bar fields (model name,
  // working dir, reasoning effort). Those render as plain text, so a hover
  // tint alone stays invisible to anyone who does not already know they open
  // a picker — this is the only persistent affordance.
  function caret() {
    const el = document.createElement("span");
    el.className = "sib-caret";
    el.setAttribute("aria-hidden", "true");
    el.innerHTML =
      '<svg viewBox="0 0 16 16" width="9" height="9" aria-hidden="true">' +
      '<path d="M4 6.5L8 10.5L12 6.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' +
      '</svg>';
    return el;
  }

  // Fetches ratios for names not yet cached. Rows simply stay blank when
  // the request fails (offline, unknown model).
  async function loadPriceRatios(names) {
    const missing = Array.from(new Set(names.filter(Boolean).filter((n) => !_priceCache.has(n))));
    if (!missing.length) return;
    try {
      const res = await fetch("/api/model_prices?models=" + encodeURIComponent(missing.join(",")));
      if (!res.ok) return;
      const data = await res.json();
      missing.forEach((n) => {
        const p = data && data.prices && data.prices[n];
        _priceCache.set(n, p ? { in: p.in, out: p.out, label: _fmtRatio(p.ratio) } : null);
      });
    } catch (e) {
      /* network error - leave prices hidden */
    }
  }

  function getPrice(name) {
    return _priceCache.get(name) || null;
  }

  // Provider label for a row: the preset name resolved server-side (same
  // rules the rest of the app uses), localised when the preset ships a
  // name_key. Returns "" for endpoints with no known provider — those rows
  // fall back to the raw host.
  function providerLabel(m) {
    if (!m || !m.provider_name) return "";
    const key = m.provider_name_key;
    if (key && typeof I18n !== "undefined") {
      const translated = I18n.t(key);
      if (translated && translated !== key) return translated;
    }
    return m.provider_name;
  }

  // Render one latency cell based on a cached result.
  //   undefined    → empty slot
  //   { ok:true }  → "812ms" in green/amber/red per threshold
  //   { ok:false } → "✕" with error in tooltip
  //   { pending:true } → "…" spinner-ish marker
  function fillLatencyCell(el, entry) {
    el.className = "sib-model-latency";
    el.textContent = "";
    el.removeAttribute("title");
    if (!entry) return;
    if (entry.pending) {
      el.textContent = "…";
      el.classList.add("is-pending");
      return;
    }
    if (!entry.ok) {
      el.textContent = "✕";
      el.classList.add("is-err");
      el.title = entry.error || "failed";
      return;
    }
    const ms = entry.ttft_ms;
    // Same thresholds as the sib-signal status bar — keep them aligned.
    let cls = "is-bad";
    if      (ms <= 2000)   cls = "is-ok";
    else if (ms <= 60000)  cls = "is-ok";
    else if (ms <= 120000) cls = "is-warn";
    el.classList.add(cls);
    el.textContent = ms >= 1000 ? (ms / 1000).toFixed(1) + "s" : ms + "ms";
    if (typeof I18n !== "undefined") {
      el.title = I18n.t("sib.bench.latencyTooltip", {
        ttft: el.textContent,
        time: new Date(entry.ts).toLocaleTimeString(),
      });
    } else {
      el.title = `TTFT ${el.textContent} · tested ${new Date(entry.ts).toLocaleTimeString()}`;
    }
  }

  // ── Sub-model variant panel ─────────────────────────────────────────────
  let _activeSubmodelAnchor = null;

  function closeSubmodelPanel() {
    const panel = document.getElementById("sib-submodel-panel");
    if (panel) panel.style.display = "none";
    if (_activeSubmodelAnchor) {
      const btn = _activeSubmodelAnchor.querySelector(".sib-submodel-toggle");
      if (btn) btn.setAttribute("aria-expanded", "false");
      _activeSubmodelAnchor.classList.remove("submodel-open");
      _activeSubmodelAnchor = null;
    }
  }

  function _renderSubmodelPanel(panel, subInfo, onSwitchSubModel) {
    panel.innerHTML = "";

    const header = document.createElement("div");
    header.className = "sib-submodel-panel-header";
    header.textContent = I18n.t("sib.variant.header");
    if (subInfo.cardModel) {
      const cardName = document.createElement("span");
      cardName.className = "sib-submodel-panel-model";
      cardName.textContent = subInfo.cardModel;
      header.appendChild(cardName);
    }
    panel.appendChild(header);

    const cardDefault = subInfo.cardModel;
    subInfo.options.forEach(name => {
      const row = document.createElement("div");
      row.className = "sib-submodel-row";
      row.dataset.subModel = name;

      const isActive = subInfo.current
        ? name === subInfo.current
        : name === cardDefault;
      if (isActive) row.classList.add("current");

      const nameEl = document.createElement("span");
      nameEl.className = "sib-submodel-row-name";
      nameEl.appendChild(vendorBadge(name));
      const nameText = document.createElement("span");
      nameText.className = "sib-submodel-row-text";
      nameText.textContent = name;
      nameEl.appendChild(nameText);
      row.appendChild(nameEl);

      const rightBox = document.createElement("span");
      rightBox.style.cssText = "display:inline-flex;align-items:center;gap:0.375rem;flex-shrink:0;";

      const priceEl = document.createElement("span");
      priceEl.className = "sib-model-price";
      rightBox.appendChild(priceEl);

      if (name === cardDefault) {
        const tag = document.createElement("span");
        tag.className = "sib-submodel-default-tag";
        tag.textContent = I18n.t("sib.variant.default");
        rightBox.appendChild(tag);
      }
      row.appendChild(rightBox);

      row.addEventListener("click", (ev) => {
        ev.stopPropagation();
        const passName = (name === cardDefault) ? null : name;
        onSwitchSubModel(passName, name);
      });
      panel.appendChild(row);
    });

    _fillSubmodelPrices(panel);
  }

  // Ratio text fills in asynchronously once /api/model_prices responds
  // (cached afterwards, so re-opening the panel shows prices instantly).
  async function _fillSubmodelPrices(panel) {
    const rows = Array.from(panel.querySelectorAll(".sib-submodel-row"));
    await loadPriceRatios(rows.map((r) => r.dataset.subModel));
    rows.forEach((row) => {
      const price = _priceCache.get(row.dataset.subModel);
      const el = row.querySelector(".sib-model-price");
      if (!price || !el || el.textContent) return;
      el.textContent = price.label;
      el.title = I18n.t("sib.price.tip", { in: price.in, out: price.out });
    });
  }

  function _toggleSubmodelPanel(container, anchorRow, btn, subInfo, onSwitchSubModel) {
    const panel = document.getElementById("sib-submodel-panel");
    if (!panel || !container) return;

    if (panel.parentElement !== document.body) {
      document.body.appendChild(panel);
    }

    const isOpen = panel.style.display !== "none" && _activeSubmodelAnchor === anchorRow;
    if (isOpen) {
      closeSubmodelPanel();
      return;
    }

    _renderSubmodelPanel(panel, subInfo, onSwitchSubModel);

    // Reset any prior position so measurements are accurate.
    panel.style.left = "0px";
    panel.style.top = "0px";
    panel.style.display = "block";
    panel.style.visibility = "hidden";

    const dropRect = container.getBoundingClientRect();
    const btnRect = (btn || anchorRow).getBoundingClientRect();
    const panelRect = panel.getBoundingClientRect();
    const gap = 6;
    const margin = 8;
    const vw = window.innerWidth;
    const vh = window.innerHeight;

    // Prefer right of dropdown; flip to left if we'd overflow viewport.
    let left = dropRect.right + gap;
    if (left + panelRect.width > vw - margin) {
      left = dropRect.left - panelRect.width - gap;
    }
    if (left < margin) left = margin;

    let top = btnRect.top - 6;
    if (top + panelRect.height > vh - margin) {
      top = vh - margin - panelRect.height;
    }
    if (top < margin) top = margin;

    panel.style.left = `${left}px`;
    panel.style.top = `${top}px`;
    panel.style.visibility = "";

    _activeSubmodelAnchor = anchorRow;
    anchorRow.classList.add("submodel-open");
    if (btn) btn.setAttribute("aria-expanded", "true");
  }

  // Open the quick-switch panel anchored to any element. The session info bar
  // caret uses this to reach the same panel without opening the full picker.
  function toggleSubmodelPanel(anchorEl, subInfo, onSwitchSubModel) {
    const panel = document.getElementById("sib-submodel-panel");
    if (!panel) return false;
    _toggleSubmodelPanel(anchorEl, anchorEl, null, subInfo, onSwitchSubModel);
    return panel.style.display !== "none";
  }

  // ── Benchmark runner ────────────────────────────────────────────────────
  async function _runBenchmark(container, btn, label, hint, onBenchmark) {
    if (_benchInFlight) return;
    _benchInFlight = true;
    btn.disabled = true;
    const origLabel = label.textContent;
    const _t = (key, vars) => (typeof I18n !== "undefined") ? I18n.t(key, vars) : key;
    label.textContent = _t("sib.bench.running");
    hint.textContent = "";

    // Mark every row as pending so the user sees instant feedback.
    container.querySelectorAll(".sib-model-option").forEach(opt => {
      const id = opt.dataset.modelId;
      if (!id) return;
      _benchCache[id] = { pending: true };
      fillLatencyCell(opt.querySelector(".sib-model-latency"), _benchCache[id]);
    });

    const t0 = performance.now();
    try {
      const results = await onBenchmark();
      const now = Date.now();
      (results || []).forEach(r => {
        _benchCache[r.model_id] = {
          ok: !!r.ok,
          ttft_ms: r.ttft_ms,
          error: r.error,
          ts: now,
        };
        const opt = container.querySelector(`.sib-model-option[data-model-id="${CSS.escape(r.model_id)}"]`);
        if (opt) fillLatencyCell(opt.querySelector(".sib-model-latency"), _benchCache[r.model_id]);
      });

      const elapsed = ((performance.now() - t0) / 1000).toFixed(1);
      hint.textContent = _t("sib.bench.done", { t: elapsed });
    } catch (e) {
      console.error("Benchmark failed:", e);
      hint.textContent = _t("sib.bench.failed", { msg: e.message });
      container.querySelectorAll(".sib-model-option").forEach(opt => {
        const id = opt.dataset.modelId;
        if (id && _benchCache[id] && _benchCache[id].pending) {
          _benchCache[id] = undefined;
          fillLatencyCell(opt.querySelector(".sib-model-latency"), undefined);
        }
      });
    } finally {
      _benchInFlight = false;
      btn.disabled = false;
      label.textContent = origLabel;
    }
  }

  // ── Generation footer ───────────────────────────────────────────────────
  function _renderFooter(container, mediaCaps, onConfigureMedia) {
    const kinds = ["image", "video", "audio"];
    const footer = document.createElement("div");
    footer.className = "sib-gen-footer";

    const list = document.createElement("span");
    list.className = "sib-gen-list";
    kinds.forEach(k => {
      const cap = mediaCaps[k] || {};
      const ok = !!cap.configured;
      const chip = document.createElement("span");
      chip.className = "sib-gen-chip " + (ok ? "is-ok" : "is-off");
      chip.textContent = (ok ? "✓ " : "") + I18n.t(`sib.gen.kind.${k}`);
      chip.title = ok
        ? I18n.t("sib.gen.okTip", { model: cap.model || "" })
        : I18n.t("sib.gen.offTip");
      list.appendChild(chip);
    });
    footer.appendChild(list);

    const configBtn = document.createElement("button");
    configBtn.type = "button";
    configBtn.className = "sib-gen-config";
    configBtn.textContent = I18n.t("sib.gen.config");
    configBtn.title = I18n.t("sib.gen.offTip");
    configBtn.addEventListener("click", (ev) => {
      ev.stopPropagation();
      onConfigureMedia();
    });
    footer.appendChild(configBtn);

    container.appendChild(footer);
  }

  // ── Main entry point ────────────────────────────────────────────────────
  // opts:
  //   models           [{id, model, type, remark, base_url, api_key_masked, ...}]
  //   currentId        id of the currently-selected model
  //   onSelect(model)  selection callback (required)
  //   mediaCaps        {vision, image, video, audio} — enables vision badge + footer
  //   subInfo          {options, current, cardModel} — enables sub-model panel
  //   onSwitchSubModel (name|null, displayName) — required when subInfo given
  //   onBenchmark      async () => [{model_id, ok, ttft_ms, error}] — enables ⚡
  //   onConfigureMedia () => void — required when mediaCaps given
  async function populate(container, opts) {
    const {
      models, currentId, onSelect,
      mediaCaps, subInfo, onSwitchSubModel,
      onBenchmark, onConfigureMedia,
    } = opts;

    container.innerHTML = "";

    // Benchmark floating button (top-right of dropdown).
    if (onBenchmark) {
      const bench = document.createElement("div");
      bench.className = "sib-model-bench";
      const btnLabel   = (typeof I18n !== "undefined") ? I18n.t("sib.bench.btn")     : "Benchmark";
      const btnTooltip = (typeof I18n !== "undefined") ? I18n.t("sib.bench.tooltip") : "Test response latency for every configured model";
      bench.innerHTML = `
        <button type="button" class="sib-bench-btn" title="${btnTooltip}">⚡ <span class="sib-bench-label">${btnLabel}</span></button>
        <span class="sib-bench-hint"></span>
      `;
      container.appendChild(bench);

      const benchBtn   = bench.querySelector(".sib-bench-btn");
      const benchLabel = bench.querySelector(".sib-bench-label");
      const benchHint  = bench.querySelector(".sib-bench-hint");
      benchBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        _runBenchmark(container, benchBtn, benchLabel, benchHint, onBenchmark);
      });
    }

    // Model rows.
    models.forEach(m => {
      const opt = document.createElement("div");
      opt.className = "sib-model-option";
      opt.dataset.modelId = m.id;
      if (m.id === currentId) opt.classList.add("current");

      const left = document.createElement("span");
      left.className = "sib-model-name";

      const nameLine = document.createElement("span");
      nameLine.className = "sib-model-name-main";
      // When a non-default quick-switch model is active, show only that
      // model's name (avoid the long "main → quick-switch" truncated string).
      const hasActiveOverride =
        m.id === currentId &&
        subInfo && subInfo.current &&
        subInfo.current !== subInfo.cardModel;
      const displayName = hasActiveOverride ? subInfo.current : m.model;
      nameLine.appendChild(vendorBadge(displayName));
      const nameText = document.createElement("span");
      nameText.className = "sib-model-name-text";
      nameText.textContent = displayName;
      nameLine.appendChild(nameText);
      left.appendChild(nameLine);

      // Vision status for the active model only.
      if (m.id === currentId && mediaCaps && mediaCaps.vision) {
        const ok = !!mediaCaps.vision.configured;
        const vis = document.createElement("span");
        vis.className = "sib-model-vision " + (ok ? "is-ok" : "is-missing");
        vis.textContent = ok ? I18n.t("sib.vision.ok") : I18n.t("sib.vision.missing");
        vis.title = ok ? I18n.t("sib.vision.okTip") : I18n.t("sib.vision.missingTip");
        nameLine.appendChild(vis);
      }

      // Provider line: which service the model runs through (plus the user's own
      // remark). Rendered on every row so two rows with the same model name are
      // never ambiguous. The endpoint host and the masked key are technical
      // details: they stay out of the line and live in the tooltip instead.
      const remark = (m.remark || "").trim();
      const host = (() => {
        try { return new URL(m.base_url).host; } catch { return m.base_url || ""; }
      })();
      const provider = providerLabel(m);
      // Unknown endpoints (no matching provider preset) fall back to the host
      // so a row never renders an empty second line.
      const identityBits = [provider || host, remark].filter(Boolean);
      if (identityBits.length) {
        left.classList.add("has-sub");
        const subLine = document.createElement("span");
        subLine.className = "sib-model-name-sub";
        subLine.textContent = identityBits.join(" · ");
        left.appendChild(subLine);
      }
      const tipBits = [provider, host, remark, m.api_key_masked].filter(Boolean);
      if (tipBits.length) opt.title = `${m.model} · ${tipBits.join(" · ")}`;

      opt.appendChild(left);

      const right = document.createElement("span");
      right.className = "sib-model-right";

      if (m.id === currentId) {
        const check = document.createElement("span");
        check.className = "sib-model-check";
        check.innerHTML =
          '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">' +
          '<path d="M3 8.5L6.5 12L13 4.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>' +
          '</svg>';
        right.appendChild(check);
      }

      if (m.type === "default" || m.type === "lite") {
        const badge = document.createElement("span");
        badge.className = `model-badge ${m.type}`;
        // Reuses the Settings badge labels so both surfaces stay in sync.
        const labelKey = `settings.models.badge.${m.type}`;
        badge.textContent = (typeof I18n !== "undefined") ? I18n.t(labelKey) : m.type;
        right.appendChild(badge);
      }

      if (onBenchmark) {
        const lat = document.createElement("span");
        lat.className = "sib-model-latency";
        fillLatencyCell(lat, _benchCache[m.id]);
        right.appendChild(lat);
      }

      const hasSubModels =
        m.id === currentId &&
        subInfo && subInfo.options &&
        subInfo.options.length > 1;

      if (hasSubModels && onSwitchSubModel) {
        const toggleBtn = document.createElement("button");
        toggleBtn.type = "button";
        toggleBtn.className = "sib-submodel-toggle";
        toggleBtn.title = I18n.t("sib.variant.header");
        toggleBtn.setAttribute("aria-expanded", "false");
        toggleBtn.innerHTML =
          '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true">' +
          '<path d="M6 3.5L10.5 8 6 12.5" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>' +
          '</svg>';
        right.appendChild(toggleBtn);

        toggleBtn.addEventListener("click", (ev) => {
          ev.stopPropagation();
          _toggleSubmodelPanel(container, opt, toggleBtn, subInfo, onSwitchSubModel);
        });
      }

      opt.appendChild(right);

      opt.addEventListener("click", () => onSelect(m));
      container.appendChild(opt);
    });

    // Generation footer.
    if (mediaCaps && onConfigureMedia) {
      _renderFooter(container, mediaCaps, onConfigureMedia);
    }
  }

  return {
    vendorBadge,
    caret,
    loadPriceRatios,
    getPrice,
    populate,
    closeSubmodelPanel,
    toggleSubmodelPanel,
  };
})();
