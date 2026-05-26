extends Node
## Penz Design System — centralized tokens and factories.
## Every UI file preloads this instead of duplicating constants.

# ── Palette ──────────────────────────────────────────────────────────
# Warm neutrals — paper + ink, not cold gray

const PAPER := Color(0.96, 0.95, 0.93)          # warm off-white canvas
const PAPER_WARM := Color(0.98, 0.97, 0.95)      # slightly warmer (text areas)
const INK := Color(0.08, 0.07, 0.07)             # warm near-black
const CHROME_BG := Color(0.12, 0.11, 0.10, 0.88) # warm dark UI bars
const CHROME_RAISED := Color(0.16, 0.15, 0.14)   # slightly lighter raised surfaces
const ACCENT := Color(0.35, 0.38, 0.52)          # muted indigo
const ACCENT_LITE := Color(0.45, 0.48, 0.65)     # lighter variant for hover
const ERROR_RED := Color(0.72, 0.28, 0.28)       # warm red

const TEXT_PRIMARY := Color(0.95, 0.94, 0.92)     # warm white
const TEXT_SECONDARY := Color(0.65, 0.63, 0.60)   # warm gray
const TEXT_TERTIARY := Color(0.45, 0.43, 0.40)    # quiet gray
const TEXT_ON_PAPER := Color(0.15, 0.14, 0.13)    # dark text on paper bg
const DOT_GRID := Color(0.80, 0.78, 0.75, 0.5)   # faint dot grid on paper
const VIEWER_BG := Color(0.05, 0.05, 0.05, 0.95) # full-screen page viewer

# ── Spacing & Radii ──────────────────────────────────────────────────

const UI_SCALE := 3.0

const CORNER_S := 6
const CORNER_M := 10
const CORNER_L := 16
const CORNER_XL := 24

const PAD_S := 4.0 * UI_SCALE
const PAD_M := 8.0 * UI_SCALE
const PAD_L := 16.0 * UI_SCALE
const PAD_XL := 24.0 * UI_SCALE

# ── Unicode Icons (cross-platform safe) ──────────────────────────────

const ICON_NEW := "+"
const ICON_SYNC := "⟳"
const ICON_SETTINGS := "⚙"
const ICON_CLOSE := "✕"
const ICON_DONE := "✓"
const ICON_FONT := "Aa"
const ICON_GALLERY := "⊞"
const ICON_CONNECT := "◉"
const ICON_OCR := "T"
const ICON_MINUS := "−"
const ICON_PLUS := "+"

# ── Style Factories ──────────────────────────────────────────────────

static func make_chrome_bg() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = CHROME_BG
	s.set_corner_radius_all(CORNER_M)
	return s


static func make_panel_bg() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(CHROME_BG.r, CHROME_BG.g, CHROME_BG.b, 0.95)
	s.set_corner_radius_all(CORNER_L)
	s.set_border_width_all(1)
	s.border_color = Color(1, 1, 1, 0.06)
	return s


static func make_card_bg(selected := false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = PAPER
	s.set_corner_radius_all(CORNER_M)
	s.set_border_width_all(1)
	s.border_color = Color(0, 0, 0, 0.08) if not selected else ACCENT
	if selected:
		s.set_border_width_all(2)
	return s


static func make_button_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color.TRANSPARENT
	s.set_corner_radius_all(CORNER_S)
	s.content_margin_left = PAD_M
	s.content_margin_right = PAD_M
	s.content_margin_top = PAD_S
	s.content_margin_bottom = PAD_S
	return s


static func make_button_hover() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1, 1, 1, 0.06)
	s.set_corner_radius_all(CORNER_S)
	s.content_margin_left = PAD_M
	s.content_margin_right = PAD_M
	s.content_margin_top = PAD_S
	s.content_margin_bottom = PAD_S
	return s


static func make_button_pressed() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(1, 1, 1, 0.10)
	s.set_corner_radius_all(CORNER_S)
	s.content_margin_left = PAD_M
	s.content_margin_right = PAD_M
	s.content_margin_top = PAD_S
	s.content_margin_bottom = PAD_S
	return s


static func make_accent_button() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ACCENT
	s.set_corner_radius_all(CORNER_S)
	s.content_margin_left = PAD_L
	s.content_margin_right = PAD_L
	s.content_margin_top = PAD_M
	s.content_margin_bottom = PAD_M
	return s


static func make_ghost_button() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color.TRANSPARENT
	s.set_corner_radius_all(CORNER_S)
	s.set_border_width_all(1)
	s.border_color = TEXT_TERTIARY
	s.content_margin_left = PAD_L
	s.content_margin_right = PAD_L
	s.content_margin_top = PAD_M
	s.content_margin_bottom = PAD_M
	return s


# ── Button Factories ─────────────────────────────────────────────────

static func make_text_button(text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.flat = false
	btn.add_theme_stylebox_override("normal", make_button_style())
	btn.add_theme_stylebox_override("hover", make_button_hover())
	btn.add_theme_stylebox_override("pressed", make_button_pressed())
	btn.add_theme_color_override("font_color", TEXT_SECONDARY)
	btn.add_theme_color_override("font_hover_color", TEXT_PRIMARY)
	btn.add_theme_color_override("font_pressed_color", TEXT_PRIMARY)
	btn.add_theme_font_size_override("font_size", int(13 * UI_SCALE))
	btn.pressed.connect(callback)
	return btn


static func make_icon_button(icon: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = icon
	btn.flat = false
	btn.add_theme_stylebox_override("normal", make_button_style())
	btn.add_theme_stylebox_override("hover", make_button_hover())
	btn.add_theme_stylebox_override("pressed", make_button_pressed())
	btn.add_theme_color_override("font_color", TEXT_SECONDARY)
	btn.add_theme_color_override("font_hover_color", TEXT_PRIMARY)
	btn.add_theme_color_override("font_pressed_color", TEXT_PRIMARY)
	btn.add_theme_font_size_override("font_size", int(16 * UI_SCALE))
	btn.custom_minimum_size = Vector2(40 * UI_SCALE, 40 * UI_SCALE)
	btn.pressed.connect(callback)
	return btn


static func make_icon_label_button(icon: String, label: String, callback: Callable) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var btn := Button.new()
	btn.text = icon
	btn.flat = false
	btn.add_theme_stylebox_override("normal", make_button_style())
	btn.add_theme_stylebox_override("hover", make_button_hover())
	btn.add_theme_stylebox_override("pressed", make_button_pressed())
	btn.add_theme_color_override("font_color", TEXT_SECONDARY)
	btn.add_theme_color_override("font_hover_color", TEXT_PRIMARY)
	btn.add_theme_font_size_override("font_size", int(16 * UI_SCALE))
	btn.custom_minimum_size = Vector2(40 * UI_SCALE, 32 * UI_SCALE)
	btn.pressed.connect(callback)
	vbox.add_child(btn)

	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", TEXT_TERTIARY)
	lbl.add_theme_font_size_override("font_size", int(9 * UI_SCALE))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)

	return vbox
