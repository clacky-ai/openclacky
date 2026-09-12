# Compact Enterprise Login Entry

## Context

OpenClacky first-run setup primarily serves personal users. The current enterprise login card gives the enterprise path the same visual weight as the personal OpenClacky AI Keys offer, making the personal onboarding page longer and diluting its primary action.

Enterprise login remains an important secondary path, but it should not compete with the personal setup flow. The underlying enterprise device authorization, platform-source switching, license validation, and managed-model behavior remain unchanged.

## Experience

The personal OpenClacky AI Keys card and manual API key option keep their existing hierarchy and behavior. A single low-emphasis text link appears at the bottom of the model setup choices:

- Chinese: `企业用户？登录企业账号 →`
- English: `Enterprise user? Sign in →`

Selecting the link replaces the choice area with the existing enterprise website address form. The user can continue to browser authorization or cancel and return to the original personal choices. The enterprise address is not persisted until authorization succeeds.

The enterprise form does not repeat a marketing card, feature description, or other content already implied by the link. Pending, error, cancellation, and success states continue to use the existing device-login flow. Enterprise success messaging shows the enterprise model and omits personal trial credit language.

Branded clients continue to hide the public OpenClacky AI Keys promotion. They retain manual model configuration and the same compact enterprise login link.

## Safety and compatibility

- Personal device authorization and manual API key setup do not change.
- Opening or cancelling enterprise login does not modify local configuration.
- Invalid enterprise addresses and failed authorization leave the current platform source, identity, brand, license, and model configuration unchanged.
- Successful authorization validates the full response before saving the enterprise platform source, device identity, Gateway endpoint, default model, and enterprise-managed model catalog as one coordinated onboarding outcome.
- The client does not invent additional models when the upstream OpenClacky device grant exposes only one model.
- Chinese and English copy remain aligned.

## Acceptance scenarios

1. A fresh personal user sees the OpenClacky AI Keys card, the manual configuration option, and only one compact enterprise login link at the bottom.
2. Selecting the enterprise link shows the enterprise website address form; cancelling restores the original personal choices.
3. Starting personal device authorization behaves exactly as before.
4. An invalid enterprise address or failed authorization does not persist any partial enterprise state.
5. A successful enterprise authorization shows enterprise-specific success content and configures the managed enterprise model catalog.
6. A branded client hides the public AI Keys promotion while retaining manual configuration and the compact enterprise login link.

## PR scope

The official pull request includes the complete client-side enterprise device-login capability, enterprise license presentation, enterprise-managed multi-model support, and this compact onboarding entry. The known single-model limitation of the current `openclacky.com` device grant is documented as an external service limitation and is not bypassed in the client.
