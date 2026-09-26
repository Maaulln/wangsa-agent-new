---
name: Wangsa Mobile
description: Native Android work surfaces with indigo actions and quiet neutral structure.
colors:
  background: "#FAFAFA"
  surface: "#FFFFFF"
  surface-muted: "#F4F4F5"
  foreground: "#18181B"
  foreground-muted: "#71717A"
  border: "#E4E4E7"
  primary: "#4F46E5"
  primary-subtle: "#EEF2FF"
  primary-active: "#3730A3"
  danger: "#DC2626"
  danger-subtle: "#FEF2F2"
  background-dark: "#09090B"
  surface-dark: "#18181B"
  surface-muted-dark: "#27272A"
  foreground-dark: "#FAFAFA"
  foreground-muted-dark: "#A1A1AA"
  border-dark: "#27272A"
  primary-dark: "#818CF8"
  primary-subtle-dark: "#1E1B4B"
  primary-muted-dark: "#C7D2FE"
typography:
  headline-small:
    fontFamily: "Roboto"
    fontSize: "24px"
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: "0px"
  title-large:
    fontFamily: "Roboto"
    fontSize: "22px"
    fontWeight: 400
    lineHeight: 1.27
    letterSpacing: "0px"
  title-medium:
    fontFamily: "Roboto"
    fontSize: "16px"
    fontWeight: 500
    lineHeight: 1.5
    letterSpacing: "0.15px"
  body-large:
    fontFamily: "Roboto"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0.5px"
  body-medium:
    fontFamily: "Roboto"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.43
    letterSpacing: "0.25px"
  body-small:
    fontFamily: "Roboto"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.33
    letterSpacing: "0.4px"
  label-large:
    fontFamily: "Roboto"
    fontSize: "14px"
    fontWeight: 500
    lineHeight: 1.43
    letterSpacing: "0.1px"
rounded:
  input: "8px"
spacing:
  gap-8: "8px"
  gap-12: "12px"
  gap-16: "16px"
  gap-20: "20px"
  gap-24: "24px"
  gap-28: "28px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.surface}"
    typography: "{typography.label-large}"
  button-text:
    textColor: "{colors.primary}"
    typography: "{typography.label-large}"
  button-outlined:
    textColor: "{colors.primary}"
    typography: "{typography.label-large}"
  input:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.input}"
    padding: "12px 14px"
  job-status:
    textColor: "{colors.foreground-muted}"
    typography: "{typography.label-large}"
---

# Design System: Wangsa Mobile

## Overview

**Creative North Star: "Native Operate UI"**

Wangsa Mobile preserves the incumbent Android Material 3 interface: bundled Roboto, indigo actions, neutral reading surfaces, and restrained outlines. Its character is calm and practical. The existing Wangsa logo remains the identity asset; this record introduces no new visual identity.

The product extension uses the existing WangsaTheme rather than defining a second theme. Native controls, readable text, and generous vertical separation carry the hierarchy. Authentication, jobs, results, and procedures share that grammar.

**Key Characteristics:**

- A single indigo action accent with neutral supporting information.
- Native Material controls and a shared Roboto hierarchy.
- Flat reading surfaces, thin separators, and a bounded scrolling column.

This record covers `lib/product/` and its shared theme in `lib/theme/wangsa_theme.dart`. Source values are Flutter logical pixels; the portable frontmatter uses `px` for their unscaled equivalents, never device screenshot pixels. Typography remains responsive to Android text scaling. Light login, jobs, and result screens were inspected from native emulator captures at 1080 × 2400; dark and remaining states are recorded from code, not visually certified.

## Colors

The palette combines saturated indigo controls with near-white surfaces, charcoal text, and cool gray supporting details.

### Primary

- **Indigo** (`primary`): filled actions, text actions, focused field borders, and active job status.
- **Pale indigo / deep indigo** (`primary-subtle`, `primary-active`): the incumbent theme's primary container pair, inherited by components that request these roles.
- **Dark-mode indigo** (`primary-dark`, `primary-subtle-dark`, `primary-muted-dark`): corresponding primary, container, and container-content roles from the existing dark theme.

### Neutral

- **Canvas and surface** (`background`, `surface`): page canvas and filled fields; their dark counterparts preserve the same role mapping.
- **Muted surface** (`surface-muted`): highest surface-container role, with its dark equivalent.
- **Charcoal and cool gray** (`foreground`, `foreground-muted`): principal and secondary text. Dark equivalents reverse the contrast hierarchy.
- **Quiet outline** (`border`): field borders and list separators; `border-dark` serves the same role in dark mode.
- The theme maps `secondary` to muted foreground. Native navigation inherits secondary-container behavior; the captured selected indicator is gray, not a second branded accent.

Error roles use `danger` and `danger-subtle`. Failure text and failed-job status use the semantic error role. The existing dark error-container mapping is an implementation detail awaiting visual review, not a new palette recommendation.

**The Existing Theme Rule.** Resolve screen colors through WangsaTheme and ColorScheme; extend the incumbent identity instead of inventing a second palette.

## Typography

**Body and UI font:** bundled Roboto. There is no separate display or monospace identity for this product surface.

The ramp is inherited from Flutter Material 3, with regular headings and medium-weight list titles and action labels. The frontmatter records repeated roles from the shipped code. `headlineMedium` appears on authentication only and remains a native role rather than a new product display token.

### Hierarchy

- **Headline small:** page-level task, job, procedure, and account headings.
- **Title large:** result and activity section headings and native app-bar titles.
- **Title medium:** job names in the collection.
- **Body large:** introductory authentication text and native input text.
- **Body medium:** explanatory content and ordinary paragraphs.
- **Body small:** event dates and secondary metadata.
- **Label large:** actions and job statuses.

Results and procedures use `MarkdownBody` with inherited rendering defaults. Report-provided headings are content structure, not additional app heading tokens.

**The Role Before Size Rule.** Use the inherited TextTheme roles for headings, body copy, and labels instead of individually sizing each screen.

## Layout

`ProductBody` aligns a scrollable column to the top center and limits its outer width to 680 logical pixels. Its content padding is 24 on the top and sides and 40 at the bottom. Screens wrap content in `SafeArea`; app bars and bottom navigation sit in the native `Scaffold` slots.

Repeated vertical gaps follow a four-unit rhythm. Short relationships use the smaller steps; explanatory blocks, form groups, and sections use the larger steps. Full-width form actions align with the fields. Collection rows have 12 logical pixels of vertical content padding, with an 8-unit gap inside status metadata. The layout narrows naturally; the product code defines no breakpoint or alternative grid.

## Elevation & Depth

App bars have zero elevation both at rest and when scrolled under. The inherited card theme is also flat and outlined, but product job collections use rows and dividers rather than cards. Standard Material buttons and dialogs retain their native state treatments; the flat app-bar rule is not a prohibition on Material interaction elevation.

**The Flat Reading Surface Rule.** Keep app bars and reading surfaces flat; use spacing, text hierarchy, and thin dividers to separate content.

## Shapes

Filled outlined fields use the shared input radius. Main actions retain Material stadium shapes. Navigation indicators are native stadium shapes too. Thin dividers establish row boundaries. The shared theme contains a 12-unit card radius, but no product Card component is used here, so it is not promoted into the product token set.

## Components

### Buttons

Native and direct. `FilledButton` is the main action, `TextButton` handles supporting actions, and `OutlinedButton` is used for cancellation and sign-out. The shared `productButtonStyle` sets a minimum size of 48 × 48 logical pixels; it does not impose a fixed height or override Material shape, padding, or state overlays. Busy actions become disabled and carry progress wording. Native dialog actions retain their own defaults.

### Inputs / Fields

Quiet white surfaces in the light theme, thin outlines, and the shared input radius. The dense decoration has 14-unit horizontal and 12-unit vertical padding. Focus changes the outline to primary. Labels, helper text, validation messages, and obscured secret fields use native form behavior. Multiline fields grow within their declared line limits.

### Navigation

A native app bar names each surface. Detail pages use the native back action. The shell's three labeled NavigationBar destinations use outlined inactive icons and filled selected icons. Refresh is an IconButton with a tooltip. Material owns focus, press, and selection animations; the product layer adds no custom motion tokens.

### Job rows and status

A divided ListTile presents the title, status, local timestamp, and trailing chevron. `JobStatus` pairs an 18-unit native icon with a flexible label and an 8-unit gap. Active jobs use primary, failed jobs use error, and other statuses use muted foreground. The status is not rendered as a chip or pill.

### Reading and feedback

Results and procedures render selectable Markdown in the page column. Activity entries use a message followed by a smaller timestamp. `ProductError` displays error-colored text with optional retry action and an accessibility label. Native progress indicators represent loading. No decorative hero, custom chart, or card grid is part of this surface.

The sidecar's HTML snippets are portable previews of these native components. They approximate Flutter rendering and interaction; the Dart widgets and Material defaults remain authoritative. Generated tonal ramps are swatch exploration metadata only.

## Do's and Don'ts

### Do:

- Do use the shared ProductBody column for product screens.
- Do use the shared 48 logical-pixel minimum button size for main form actions.
- Do pair job status text with its native status icon; color alone is insufficient.
- Do keep long results and procedures selectable and scrollable.
- Do preserve the bundled Roboto family and existing Wangsa logo.

### Don't:

- Don't replace native product controls with a new brand treatment.
- Don't present every job as a raised card; the shipped collection uses divided list rows.
- Don't hard-code light colors into widgets that already consume ColorScheme.
- Don't treat generated palette ramps or HTML previews as new Flutter theme tokens.
