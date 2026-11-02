# HongMix 1.3.24 (Build 39)

## Input tile folding

- Added a visible chevron control on every input header to fold the card to its title bar and expand it again.
- Added a separate persisted `folded` state, so title-only folding no longer shares the compact-thumbnail setting.
- Right-clicking a title and the Input panel's “All Inputs Fold/Expand” commands now fold/unfold cards to the title bar. Compact tile mode remains a separate thumbnail layout.
- Existing project files load with inputs unfolded unless their saved fold state is present.

## Verification limits

- Release app compilation completed. This release has not been exercised in a live broadcast session.
