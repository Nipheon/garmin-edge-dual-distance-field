import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Blue used by the device to separate data fields.
const DIVIDER_COLOR = 0x007DC3;

const CELL_PAD    = 2;   // gap at left and right edges
const ICON_ZONE_W = 30;  // width reserved for the icon column
const ICON_SIZE   = 18;  // icon render size in pixels (stacked rows)
// Icon size in the side-by-side layout: full-height cells fit a larger icon
// than the stacked rows, but 22 is the ceiling on 282px-wide screens before
// the icon zone starts costing the value a font-size step.
const SPLIT_ICON_SIZE = 22;

// compute() runs at 1 Hz; re-read device settings only this often to avoid
// allocating a DeviceSettings object every tick. A units change is picked up
// within this many seconds (and immediately on layout changes).
const SETTINGS_REFRESH_TICKS = 30;

// SCREENSHOT MODE — forces fixed sample data, regardless of what's actually
// happening on the device. Set SCREENSHOT_SHOW_ROUTE to switch between the two
// display states, since a loaded route can't be emulated in the simulator.
// (:debug)-only: compiled out entirely for release/store builds (-r), so this
// can never accidentally ship — no need to remember to flip it back.
(:debug) const SCREENSHOT_MODE       = true;
(:debug) const SCREENSHOT_SHOW_ROUTE = true;  // true: dual-value (route) state, false: single-value (no route) state
(:debug) const SCREENSHOT_DIST_KM      = 27.3f;
(:debug) const SCREENSHOT_REMAINING_KM = 34.2f;

class DualDistanceFieldView extends WatchUi.DataField {

    hidden var _dist       as Float;
    hidden var _remaining  as Float or Null;
    hidden var _unit       as String;
    hidden var _unitFont   as Graphics.FontType;
    hidden var _labelFont  as Graphics.FontType;
    hidden var _distanceLabel as String;
    hidden var _isMetric     as Boolean;
    hidden var _settingsTick as Number;
    hidden var _screenH      as Number;
    hidden var _screenW      as Number;
    // Descending font ladders — the largest font that fits the available space
    // is picked at draw time, so small data fields degrade instead of clipping.
    hidden var _valueFonts as Array<Graphics.FontType>;  // single-value (no route) view
    hidden var _rowFonts   as Array<Graphics.FontType>;  // dual-row (route) view

    function initialize() {
        DataField.initialize();
        _dist       = 0.0f;
        _remaining  = null;
        _unit       = "km";
        _unitFont   = Graphics.FONT_TINY;
        // Native header font differs by generation (per the device layout specs):
        // x40-era devices use the Roboto glance font, while the CIQ 3.x era
        // (530/830/1030/820/...) uses the condensed DejaVu FONT_SMALL. Key off an
        // API 4.0 symbol to tell the generations apart.
        _labelFont  = ((Graphics has :createBufferedBitmap) && (Graphics has :FONT_GLANCE))
            ? Graphics.FONT_GLANCE : Graphics.FONT_SMALL;
        _distanceLabel = WatchUi.loadResource(Rez.Strings.DistanceLabel) as String;
        _isMetric     = true;
        _settingsTick = 0;
        _screenH      = 1;
        _screenW      = 10000;
        // Custom Roboto Bold fonts (see resources/fonts) fill the size canyon
        // between NUMBER_MEDIUM (29px digits) and NUMBER_HOT (42px), and extend
        // past it toward the sizes native fields reach via scalable fonts.
        // Ladder order doesn't matter: pickFont() selects the tallest fit, since
        // built-in font sizes vary per device relative to the fixed custom ones.
        var fontBig = WatchUi.loadResource(Rez.Fonts.NumberBig) as Graphics.FontType;
        var fontLrg = WatchUi.loadResource(Rez.Fonts.NumberLrg) as Graphics.FontType;
        var fontXlg = WatchUi.loadResource(Rez.Fonts.NumberXlg) as Graphics.FontType;
        var fontMid = WatchUi.loadResource(Rez.Fonts.NumberMid) as Graphics.FontType;
        _valueFonts = [fontBig, fontLrg, fontXlg, fontMid,
                       Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM,
                       Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM,
                       Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY];
        _rowFonts   = [fontMid,
                       Graphics.FONT_NUMBER_HOT, Graphics.FONT_NUMBER_MEDIUM,
                       Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM,
                       Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY];
        refreshSettings();
    }

    hidden function refreshSettings() as Void {
        var settings = System.getDeviceSettings();
        _isMetric = (settings.distanceUnits == System.UNIT_METRIC);
        _unit     = _isMetric ? "km" : "mi";
        _screenH  = settings.screenHeight;
        _screenW  = settings.screenWidth;
    }

    // Native single-value geometry, taken from the device layout specs
    // (simulator.json): label and value are baseline-anchored at fixed
    // fractions of the field height, shifting for taller fields.
    hidden function labelBaseFrac(hFrac as Float) as Float {
        if (hFrac <= 0.45f) { return 0.29f; }
        if (hFrac <= 0.70f) { return 0.35f; }
        return 0.42f;
    }

    hidden function valueBaseFrac(hFrac as Float) as Float {
        if (hFrac <= 0.28f) { return 0.87f;  }
        if (hFrac <= 0.37f) { return 0.845f; }
        if (hFrac <= 0.45f) { return 0.78f;  }
        if (hFrac <= 0.70f) { return 0.744f; }
        return 0.62f;
    }

    function onLayout(dc as Dc) as Void {
        refreshSettings();
        View.setLayout(Rez.Layouts.MainLayout(dc));
        var lbl = View.findDrawableById("label") as Text;
        var val = View.findDrawableById("value") as Text;
        lbl.locY = lbl.locY - 16;
        val.locY = val.locY + 7;
    }

    function compute(info as Activity.Info) as Void {
        if (applyScreenshotMode()) {
            return;
        }

        _settingsTick += 1;
        if (_settingsTick >= SETTINGS_REFRESH_TICKS) {
            _settingsTick = 0;
            refreshSettings();
        }
        var factor = _isMetric ? 0.001f : 0.000621371f;

        if ((info has :elapsedDistance) && info.elapsedDistance != null) {
            _dist = (info.elapsedDistance as Float) * factor;
        } else {
            _dist = 0.0f;
        }

        if ((info has :distanceToDestination) && info.distanceToDestination != null
                && (info.distanceToDestination as Float) > 0.0f) {
            _remaining = (info.distanceToDestination as Float) * factor;
        } else {
            _remaining = null;
        }
    }

    // Applies fixed sample data when SCREENSHOT_MODE is on; returns whether it did.
    // (:debug)-only — see SCREENSHOT_MODE above. The (:release) sibling below is a
    // no-op, so store builds contain no screenshot logic or sample values at all.
    (:debug) hidden function applyScreenshotMode() as Boolean {
        if (!SCREENSHOT_MODE) {
            return false;
        }
        _unit      = "km";
        _dist      = SCREENSHOT_DIST_KM;
        _remaining = SCREENSHOT_SHOW_ROUTE ? SCREENSHOT_REMAINING_KM : null;
        return true;
    }

    (:release) hidden function applyScreenshotMode() as Boolean {
        return false;
    }

    // Drop the decimal for numbers >= 100 so three-digit values still fit.
    hidden function fmt(val as Float) as String {
        return val >= 100.0f ? val.format("%.0f") : val.format("%.1f");
    }

    // Graphics.getFontAscent/Descent arrived with CIQ 3.1; approximate on the
    // 2.4-era Edge 820/Explore firmware variants. Built-in fonts (plain Number
    // constants) put roughly 80% of the box above the baseline; the custom
    // fonts (loaded resources, not Numbers) are tight: baseline ~2px above the
    // box bottom.
    hidden function fontAscent(dc as Dc, f as Graphics.FontType) as Number {
        if (Graphics has :getFontAscent) {
            return Graphics.getFontAscent(f);
        }
        if (!(f instanceof Lang.Number)) {
            return dc.getFontHeight(f) - 2;
        }
        return dc.getFontHeight(f) * 4 / 5;
    }

    hidden function fontDescent(dc as Dc, f as Graphics.FontType) as Number {
        if (Graphics has :getFontDescent) {
            return Graphics.getFontDescent(f);
        }
        if (!(f instanceof Lang.Number)) {
            return 2;
        }
        return dc.getFontHeight(f) / 5;
    }

    // Visually largest font from the ladder whose rendered string fits
    // maxW x maxH; falls back to the ladder's smallest font if nothing fits.
    // Fonts are ranked by digit width, not box height: built-in number fonts
    // carry large internal padding (NUMBER_MEDIUM: 42px box, 29px digits)
    // while the custom fonts are tight, so box height misorders them.
    hidden function pickFont(dc as Dc, str as String, maxW as Number, maxH as Number,
                             ladder as Array<Graphics.FontType>) as Graphics.FontType {
        var best      = null;
        var bestSize  = -1;
        var smallest  = ladder[0];
        var smallSize = dc.getTextWidthInPixels("0", ladder[0]);
        for (var i = 0; i < ladder.size(); i++) {
            var f    = ladder[i];
            var size = dc.getTextWidthInPixels("0", f);
            if (size < smallSize) {
                smallest  = f;
                smallSize = size;
            }
            if (size > bestSize && dc.getFontHeight(f) <= maxH
                    && dc.getTextWidthInPixels(str, f) <= maxW) {
                best     = f;
                bestSize = size;
            }
        }
        return best != null ? best : smallest;
    }

    // Right-pointing arrow (shaft + triangular head) — traveled indicator.
    hidden function drawIconTraveled(dc as Dc, left as Number, centerY as Number, s as Number) as Void {
        var t  = s * 2 / 5;  // shaft thickness
        var hw = s / 2;      // head width
        dc.fillPolygon([
            [left,          centerY - t / 2],
            [left + s - hw, centerY - t / 2],
            [left + s - hw, centerY - s / 2],
            [left + s,      centerY],
            [left + s - hw, centerY + s / 2],
            [left + s - hw, centerY + t / 2],
            [left,          centerY + t / 2]
        ]);
    }

    // Map pin (circle head + teardrop body + punched hole).
    hidden function drawIconRemaining(dc as Dc, left as Number, centerY as Number,
                                      s as Number, holeColor as Graphics.ColorType) as Void {
        var pinR     = s * 3 / 8;
        var pinCX    = left + pinR;
        var pinHeadY = centerY - s / 10;
        var pinTipY  = centerY + pinR + s / 3;

        dc.fillPolygon([
            [pinCX - pinR * 9 / 10, pinHeadY + pinR / 2],
            [pinCX + pinR * 9 / 10, pinHeadY + pinR / 2],
            [pinCX, pinTipY]
        ]);
        dc.fillCircle(pinCX, pinHeadY, pinR);

        dc.setColor(holeColor, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(pinCX, pinHeadY, pinR / 3);
    }

    // Draw value in the given font with unit in _unitFont, bottom-aligned to the
    // value. x is the right edge of the combined value+unit.
    hidden function drawValue(dc as Dc, x as Number, y as Number, str as String,
                              font as Graphics.FontType) as Void {
        var unitW = dc.getTextWidthInPixels(_unit, _unitFont);
        // Align the unit to the value's baseline (digits sit on the baseline;
        // box-based alignment drifts by up to 11px with the tight custom fonts).
        var unitY = y + fontAscent(dc, font) - fontAscent(dc, _unitFont);

        dc.drawText(x,         unitY, _unitFont, _unit, Graphics.TEXT_JUSTIFY_RIGHT);
        dc.drawText(x - unitW, y,     font,      str,   Graphics.TEXT_JUSTIFY_RIGHT);
    }

    function onUpdate(dc as Dc) as Void {
        var bgColor = getBackgroundColor();
        var fgColor = bgColor == Graphics.COLOR_BLACK
            ? Graphics.COLOR_WHITE
            : Graphics.COLOR_BLACK;

        (View.findDrawableById("Background") as Background).setColor(bgColor);

        (View.findDrawableById("label") as Text).setText("");
        (View.findDrawableById("value") as Text).setText("");
        View.onUpdate(dc);

        var w = dc.getWidth();
        var h = dc.getHeight();

        dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);

        if (_remaining == null) {
            // ── No route: native-style field, baseline-anchored per the device
            // layout spec. Unit shares the value's baseline, like native. ──
            var hFrac    = h.toFloat() / _screenH;
            var lblBaseY = (h * labelBaseFrac(hFrac)).toNumber();
            var valBaseY = (h * valueBaseFrac(hFrac)).toNumber();
            var lblText  = _distanceLabel.toUpper();
            var lblFont  = dc.getTextWidthInPixels(lblText, _labelFont) > w - 2 * CELL_PAD
                ? Graphics.FONT_XTINY : _labelFont;
            // Very short slots (51-60px on some devices): the label must fit above
            // its baseline — step down to XTINY, or failing that push the baseline.
            if (fontAscent(dc, lblFont) + 1 > lblBaseY) {
                if (fontAscent(dc, Graphics.FONT_XTINY) + 1 <= lblBaseY) {
                    lblFont = Graphics.FONT_XTINY;
                } else {
                    lblBaseY = fontAscent(dc, lblFont) + 1;
                }
            }
            var distStr  = fmt(_dist);
            var unitW    = dc.getTextWidthInPixels(_unit, _labelFont);
            // Cap the value font at the native size rule (from the device layout
            // specs): ~50% of the slot height, but never more than ~18.5% of the
            // screen height — the largest font native fields ever use.
            var maxValH  = valBaseY - lblBaseY;
            if (h * 50 / 100 < maxValH)         { maxValH = h * 50 / 100; }
            if (_screenH * 185 / 1000 < maxValH) { maxValH = _screenH * 185 / 1000; }
            // Native keeps ~7% side margins around the value; this is what makes
            // wide values step down in size exactly where native shrinks them.
            var valFont  = pickFont(dc, distStr, w - 2 * (w * 7 / 100) - unitW, maxValH, _valueFonts);
            var valW     = dc.getTextWidthInPixels(distStr, valFont);
            var groupX   = (w - valW - unitW) / 2;

            // Center the value vertically in the band below the label — when the
            // picked font is smaller than native's, a centered value looks right
            // where the native baseline position would leave it bottom-hugging.
            var bandTop  = lblBaseY + fontDescent(dc, lblFont);
            var valTop   = bandTop + (h - 2 - bandTop - dc.getFontHeight(valFont)) / 2;
            var baseline = valTop + fontAscent(dc, valFont);

            dc.drawText(w / 2, lblBaseY - fontAscent(dc, lblFont), lblFont,
                        lblText, Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(groupX, valTop, valFont, distStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(groupX + valW, baseline - fontAscent(dc, _labelFont), _labelFont,
                        _unit, Graphics.TEXT_JUSTIFY_LEFT);

        } else if (w >= _screenW) {
            // ── Route active, full-width field: side-by-side cells split by a
            // vertical divider — ridden distance left, remaining right. ──
            var halfW   = w / 2;
            var leftStr  = fmt(_dist);
            var rightStr = fmt(_remaining as Float);
            var unitW    = dc.getTextWidthInPixels(_unit, _unitFont);

            // Full-height cells fit a larger icon than the stacked rows; hug the
            // icon with a tight zone instead of reserving the fixed 30px column,
            // so the value keeps as much width budget as possible.
            var iconSize = SPLIT_ICON_SIZE <= h - 8 ? SPLIT_ICON_SIZE : h - 8;
            var drawIcons = iconSize >= 8;
            var iconZone  = drawIcons ? iconSize + 4 : 0;

            // One font for both cells so they match; fit against the wider value.
            var probe   = dc.getTextWidthInPixels(leftStr, Graphics.FONT_NUMBER_MEDIUM)
                        > dc.getTextWidthInPixels(rightStr, Graphics.FONT_NUMBER_MEDIUM)
                        ? leftStr : rightStr;
            var cellFont = pickFont(dc, probe, halfW - 2 * CELL_PAD - iconZone - unitW, h - 4, _rowFonts);
            var numH     = dc.getFontHeight(cellFont);
            var valY     = (h - numH) / 2;
            var cy       = h / 2;

            // Left cell: arrow icon + ridden distance
            if (drawIcons) {
                drawIconTraveled(dc, CELL_PAD, cy, iconSize);
            }
            drawValue(dc, halfW - CELL_PAD - 2, valY, leftStr, cellFont);

            // Divider
            dc.setColor(DIVIDER_COLOR, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawLine(halfW, 0, halfW, h);

            // Right cell: pin icon + remaining distance
            dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            if (drawIcons) {
                drawIconRemaining(dc, halfW + CELL_PAD + iconSize / 8,
                                  cy - iconSize / 8, iconSize, bgColor);
                dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            }
            drawValue(dc, w - CELL_PAD, valY, rightStr, cellFont);

        } else {
            // ── Route active: dual row with divider ──
            var midY   = h / 2;
            var topStr = fmt(_dist);
            var botStr = fmt(_remaining as Float);
            var unitW  = dc.getTextWidthInPixels(_unit, _unitFont);

            // One font for both rows so they match; fit against the wider value.
            var probe   = dc.getTextWidthInPixels(topStr, Graphics.FONT_NUMBER_MEDIUM)
                        > dc.getTextWidthInPixels(botStr, Graphics.FONT_NUMBER_MEDIUM)
                        ? topStr : botStr;
            var rowFont = pickFont(dc, probe, w - 2 * CELL_PAD - ICON_ZONE_W - unitW, midY - 2, _rowFonts);
            var numH    = dc.getFontHeight(rowFont);

            var topY  = (midY - numH) / 2;
            var topCY = topY + numH / 2;
            var botY  = midY + (h - midY - numH) / 2;
            var botCY = botY + numH / 2;
            var iconCX = CELL_PAD + ICON_ZONE_W / 2;

            // Shrink the icons with the row height; skip them entirely when the
            // rows are too short for a legible icon.
            var iconSize = ICON_SIZE <= midY - 4 ? ICON_SIZE : midY - 4;
            var drawIcons = iconSize >= 8;

            // Top: arrow icon + ridden distance
            if (drawIcons) {
                drawIconTraveled(dc, iconCX - iconSize / 2, topCY, iconSize);
            }
            drawValue(dc, w - CELL_PAD, topY, topStr, rowFont);

            // Divider
            dc.setColor(DIVIDER_COLOR, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawLine(0, midY, w, midY);

            // Bottom: pin icon + remaining distance
            dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            if (drawIcons) {
                drawIconRemaining(dc, iconCX - iconSize * 3 / 8, botCY - iconSize / 8, iconSize, bgColor);
                dc.setColor(fgColor, Graphics.COLOR_TRANSPARENT);
            }
            drawValue(dc, w - CELL_PAD, botY, botStr, rowFont);
        }
    }

}
