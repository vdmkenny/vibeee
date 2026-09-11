/* The layout proof between lexbor's C and this program's Zig mirror.
 *
 * `lexbor.zig` hand-mirrors the structs the walk reaches into: a DOM node,
 * and the cascade's answers, a document's style state, rules, declarations
 * and colours. Comptime assertions there pin its side of every offset. This
 * file pins the C side of the same offsets against the vendored headers, so
 * a header change and a mirror change each fail the build on their own.
 *
 * Only the fields a mirror reads, and those ahead of them, are pinned. What
 * follows them is upstream's business.
 *
 * It contains no code: static assertions only.
 */
#include <stddef.h>

#include "lexbor/dom/interfaces/node.h"
#include "lexbor/dom/interfaces/event_target.h"
#include "lexbor/dom/interfaces/character_data.h"
#include "lexbor/dom/interfaces/document.h"
#include "lexbor/tag/const.h"
#include "lexbor/core/base.h"
#include "lexbor/css/rule.h"
#include "lexbor/css/stylesheet.h"
#include "lexbor/css/value.h"
#include "lexbor/css/property.h"
#include "lexbor/css/property/const.h"
#include "lexbor/css/value/const.h"
#include "lexbor/style/dom/interfaces/document.h"

#define CHECK(name, expr) _Static_assert((expr), name)

/* The one failure the mirror names: the parser running out of memory. */
CHECK("running out of memory is status 0x0002",
      LXB_STATUS_ERROR_MEMORY_ALLOCATION == 0x0002);

/* The head of a node is an event target, and an event target is one pointer.
 * Two would move every field below it, and a walk reading `type` from the
 * wrong offset finds a node kind that was never there. */
CHECK("an event target is one pointer",
      sizeof(lxb_dom_event_target_t) == sizeof(void *));

CHECK("a node begins with its event target",
      offsetof(lxb_dom_node_t, event_target) == 0);

CHECK("local_name follows the event target",
      offsetof(lxb_dom_node_t, local_name) == sizeof(void *));

CHECK("the three names are one word each",
      offsetof(lxb_dom_node_t, ns) - offsetof(lxb_dom_node_t, local_name)
          == 2 * sizeof(uintptr_t));

CHECK("the owning document follows the names",
      offsetof(lxb_dom_node_t, owner_document)
          == offsetof(lxb_dom_node_t, ns) + sizeof(uintptr_t));

CHECK("the five links are in the order the mirror walks them",
      offsetof(lxb_dom_node_t, next) < offsetof(lxb_dom_node_t, prev)
          && offsetof(lxb_dom_node_t, prev) < offsetof(lxb_dom_node_t, parent)
          && offsetof(lxb_dom_node_t, parent) < offsetof(lxb_dom_node_t, first_child)
          && offsetof(lxb_dom_node_t, first_child) < offsetof(lxb_dom_node_t, last_child));

CHECK("the user pointer follows the links",
      offsetof(lxb_dom_node_t, user)
          == offsetof(lxb_dom_node_t, last_child) + sizeof(void *));

CHECK("the node kind follows the user pointer",
      offsetof(lxb_dom_node_t, type)
          == offsetof(lxb_dom_node_t, user) + sizeof(void *));

/* What the mirror says the whole head measures, so a field inserted anywhere
 * above `type` is caught even when the relative order still holds. */
CHECK("the head of a node is eleven words",
      offsetof(lxb_dom_node_t, type) == 11 * sizeof(void *));

/* `type` is the last field, which is what lets the mirror be the whole
 * struct and a text node's words sit straight after it. */
CHECK("a node is twelve words", sizeof(lxb_dom_node_t) == 12 * sizeof(void *));

/* A text node's words, read in place by `wordsOf`: a string straight after
 * the node's head, which is a pointer and then a length. */
CHECK("a text node's words follow its head",
      offsetof(lxb_dom_character_data_t, data) == 12 * sizeof(void *));
CHECK("a string is a pointer and then a length",
      offsetof(lexbor_str_t, data) == 0
          && offsetof(lexbor_str_t, length) == sizeof(void *)
          && sizeof(lexbor_str_t) == 2 * sizeof(void *));

/* Every tag number the mirror names, against upstream's own. */
CHECK("a is 0x0007", LXB_TAG_A == 0x0007);
CHECK("address is 0x000a", LXB_TAG_ADDRESS == 0x000a);
CHECK("article is 0x0014", LXB_TAG_ARTICLE == 0x0014);
CHECK("aside is 0x0015", LXB_TAG_ASIDE == 0x0015);
CHECK("b is 0x0017", LXB_TAG_B == 0x0017);
CHECK("base is 0x0018", LXB_TAG_BASE == 0x0018);
CHECK("blockquote is 0x001f", LXB_TAG_BLOCKQUOTE == 0x001f);
CHECK("body is 0x0020", LXB_TAG_BODY == 0x0020);
CHECK("br is 0x0021", LXB_TAG_BR == 0x0021);
CHECK("button is 0x0022", LXB_TAG_BUTTON == 0x0022);
CHECK("canvas is 0x0023", LXB_TAG_CANVAS == 0x0023);
CHECK("caption is 0x0024", LXB_TAG_CAPTION == 0x0024);
CHECK("center is 0x0025", LXB_TAG_CENTER == 0x0025);
CHECK("code is 0x0028", LXB_TAG_CODE == 0x0028);
CHECK("dd is 0x002d", LXB_TAG_DD == 0x002d);
CHECK("details is 0x0030", LXB_TAG_DETAILS == 0x0030);
CHECK("div is 0x0034", LXB_TAG_DIV == 0x0034);
CHECK("dl is 0x0035", LXB_TAG_DL == 0x0035);
CHECK("dt is 0x0036", LXB_TAG_DT == 0x0036);
CHECK("em is 0x0037", LXB_TAG_EM == 0x0037);
CHECK("fieldset is 0x0052", LXB_TAG_FIELDSET == 0x0052);
CHECK("figcaption is 0x0053", LXB_TAG_FIGCAPTION == 0x0053);
CHECK("figure is 0x0054", LXB_TAG_FIGURE == 0x0054);
CHECK("font is 0x0055", LXB_TAG_FONT == 0x0055);
CHECK("footer is 0x0056", LXB_TAG_FOOTER == 0x0056);
CHECK("form is 0x0058", LXB_TAG_FORM == 0x0058);
CHECK("h1 is 0x005c", LXB_TAG_H1 == 0x005c);
CHECK("h2 is 0x005d", LXB_TAG_H2 == 0x005d);
CHECK("h3 is 0x005e", LXB_TAG_H3 == 0x005e);
CHECK("h4 is 0x005f", LXB_TAG_H4 == 0x005f);
CHECK("h5 is 0x0060", LXB_TAG_H5 == 0x0060);
CHECK("h6 is 0x0061", LXB_TAG_H6 == 0x0061);
CHECK("head is 0x0062", LXB_TAG_HEAD == 0x0062);
CHECK("header is 0x0063", LXB_TAG_HEADER == 0x0063);
CHECK("hr is 0x0065", LXB_TAG_HR == 0x0065);
CHECK("html is 0x0066", LXB_TAG_HTML == 0x0066);
CHECK("i is 0x0067", LXB_TAG_I == 0x0067);
CHECK("iframe is 0x0068", LXB_TAG_IFRAME == 0x0068);
CHECK("img is 0x006a", LXB_TAG_IMG == 0x006a);
CHECK("input is 0x006b", LXB_TAG_INPUT == 0x006b);
CHECK("link is 0x0074", LXB_TAG_LINK == 0x0074);
CHECK("kbd is 0x006e", LXB_TAG_KBD == 0x006e);
CHECK("li is 0x0072", LXB_TAG_LI == 0x0072);
CHECK("main is 0x0076", LXB_TAG_MAIN == 0x0076);
CHECK("math is 0x007b", LXB_TAG_MATH == 0x007b);
CHECK("nav is 0x0087", LXB_TAG_NAV == 0x0087);
CHECK("noscript is 0x008c", LXB_TAG_NOSCRIPT == 0x008c);
CHECK("ol is 0x008e", LXB_TAG_OL == 0x008e);
CHECK("option is 0x0090", LXB_TAG_OPTION == 0x0090);
CHECK("p is 0x0092", LXB_TAG_P == 0x0092);
CHECK("pre is 0x0097", LXB_TAG_PRE == 0x0097);
CHECK("samp is 0x00a1", LXB_TAG_SAMP == 0x00a1);
CHECK("script is 0x00a2", LXB_TAG_SCRIPT == 0x00a2);
CHECK("section is 0x00a4", LXB_TAG_SECTION == 0x00a4);
CHECK("select is 0x00a5", LXB_TAG_SELECT == 0x00a5);
CHECK("strong is 0x00ad", LXB_TAG_STRONG == 0x00ad);
CHECK("style is 0x00ae", LXB_TAG_STYLE == 0x00ae);
CHECK("summary is 0x00b0", LXB_TAG_SUMMARY == 0x00b0);
CHECK("svg is 0x00b2", LXB_TAG_SVG == 0x00b2);
CHECK("table is 0x00b3", LXB_TAG_TABLE == 0x00b3);
CHECK("td is 0x00b5", LXB_TAG_TD == 0x00b5);
CHECK("template is 0x00b6", LXB_TAG_TEMPLATE == 0x00b6);
CHECK("textarea is 0x00b7", LXB_TAG_TEXTAREA == 0x00b7);
CHECK("th is 0x00ba", LXB_TAG_TH == 0x00ba);
CHECK("title is 0x00bd", LXB_TAG_TITLE == 0x00bd);
CHECK("tr is 0x00be", LXB_TAG_TR == 0x00be);
CHECK("tt is 0x00c0", LXB_TAG_TT == 0x00c0);
CHECK("ul is 0x00c2", LXB_TAG_UL == 0x00c2);
CHECK("var is 0x00c3", LXB_TAG_VAR == 0x00c3);

/* The cascade: where a document keeps it, and the shapes its answers come
 * back in. */
CHECK("a document keeps its cascade after its node, two kinds and fifteen pointers",
      offsetof(lxb_dom_document_t, css)
          == 27 * sizeof(void *) + 2 * sizeof(unsigned int));
CHECK("the cascade's parser is its third word",
      offsetof(lxb_dom_document_css_t, parser) == 2 * sizeof(void *));
CHECK("a rule's head is six words", sizeof(lxb_css_rule_t) == 6 * sizeof(void *));
CHECK("a style rule's declarations are its eighth word",
      offsetof(lxb_css_rule_style_t, declarations) == 7 * sizeof(void *));
CHECK("a declaration list starts after its head",
      offsetof(lxb_css_rule_declaration_list_t, first) == 6 * sizeof(void *));
CHECK("a declaration's property follows its head",
      offsetof(lxb_css_rule_declaration_t, type) == 6 * sizeof(void *));
CHECK("a declaration's value is its eighth word",
      offsetof(lxb_css_rule_declaration_t, u) == 7 * sizeof(void *));
CHECK("a declaration's importance follows its six offsets",
      offsetof(lxb_css_rule_declaration_t, important) == 14 * sizeof(void *));
CHECK("a stylesheet begins with its rules",
      offsetof(lxb_css_stylesheet_t, root) == 0);
CHECK("a custom declaration keeps its name and then its value",
      offsetof(lxb_css_property__custom_t, name) == 0
          && offsetof(lxb_css_property__custom_t, value) == sizeof(lexbor_str_t));
CHECK("display is three keywords",
      sizeof(lxb_css_property_display_t) == 3 * sizeof(unsigned int));
CHECK("visibility is one keyword",
      sizeof(lxb_css_property_visibility_t) == sizeof(unsigned int));
CHECK("text-align is one keyword",
      sizeof(lxb_css_property_text_align_t) == sizeof(unsigned int));
CHECK("opacity is a number or a percentage, as a channel of rgb() is",
      sizeof(lxb_css_property_opacity_t) == sizeof(lxb_css_value_number_percentage_t));
CHECK("a colour's value follows its kind",
      offsetof(lxb_css_value_color_t, u) == _Alignof(double));
CHECK("a hex colour is four bytes and then its length",
      offsetof(lxb_css_value_color_hex_t, type) == 4);
CHECK("which is one of four, three digits first, in an unsigned int",
      LXB_CSS_PROPERTY_COLOR_HEX_TYPE_3 == 0 && LXB_CSS_PROPERTY_COLOR_HEX_TYPE_4 == 1
          && LXB_CSS_PROPERTY_COLOR_HEX_TYPE_6 == 2 && LXB_CSS_PROPERTY_COLOR_HEX_TYPE_8 == 3
          && sizeof(lxb_css_value_color_hex_type_t) == sizeof(unsigned int));
CHECK("a colour channel is a kind and a number",
      sizeof(lxb_css_value_number_percentage_t)
          == _Alignof(double) + sizeof(lxb_css_value_number_t));
CHECK("rgb() keeps its channels in order",
      offsetof(lxb_css_value_color_rgba_t, g) == sizeof(lxb_css_value_number_percentage_t)
          && offsetof(lxb_css_value_color_rgba_t, a)
              == 3 * sizeof(lxb_css_value_number_percentage_t));

/* Every rule kind, property and keyword the mirror names. */
CHECK("a rule list is kind 2", LXB_CSS_RULE_LIST == 2);
CHECK("a style rule is kind 4", LXB_CSS_RULE_STYLE == 4);
CHECK("a declaration is kind 7", LXB_CSS_RULE_DECLARATION == 7);
CHECK("a property upstream does not read is 0x0001", LXB_CSS_PROPERTY__CUSTOM == 0x0001);
CHECK("background-color is 0x0006", LXB_CSS_PROPERTY_BACKGROUND_COLOR == 0x0006);
CHECK("color is 0x0015", LXB_CSS_PROPERTY_COLOR == 0x0015);
CHECK("display is 0x0017", LXB_CSS_PROPERTY_DISPLAY == 0x0017);
CHECK("opacity is 0x003e", LXB_CSS_PROPERTY_OPACITY == 0x003e);
CHECK("text-align is 0x004d", LXB_CSS_PROPERTY_TEXT_ALIGN == 0x004d);
CHECK("visibility is 0x005d", LXB_CSS_PROPERTY_VISIBILITY == 0x005d);
CHECK("center is 0x0007", LXB_CSS_VALUE_CENTER == 0x0007);
CHECK("a percentage is 0x0015", LXB_CSS_VALUE__PERCENTAGE == 0x0015);
CHECK("none is 0x001f", LXB_CSS_VALUE_NONE == 0x001f);
CHECK("hidden is 0x0020", LXB_CSS_VALUE_HIDDEN == 0x0020);
CHECK("left is 0x002f", LXB_CSS_VALUE_LEFT == 0x002f);
CHECK("right is 0x0030", LXB_CSS_VALUE_RIGHT == 0x0030);
CHECK("currentcolor is 0x0031", LXB_CSS_VALUE_CURRENTCOLOR == 0x0031);
CHECK("transparent is 0x0032", LXB_CSS_VALUE_TRANSPARENT == 0x0032);
CHECK("a hex colour is 0x0033", LXB_CSS_VALUE_HEX == 0x0033);
CHECK("rgb is 0x00db", LXB_CSS_VALUE_RGB == 0x00db);
CHECK("rgba is 0x00dc", LXB_CSS_VALUE_RGBA == 0x00dc);
CHECK("a number is 0x0108", LXB_CSS_VALUE__NUMBER == 0x0108);
CHECK("start is 0x010d", LXB_CSS_VALUE_START == 0x010d);
CHECK("end is 0x010e", LXB_CSS_VALUE_END == 0x010e);
CHECK("justify is 0x014a", LXB_CSS_VALUE_JUSTIFY == 0x014a);
CHECK("collapse is 0x0165", LXB_CSS_VALUE_COLLAPSE == 0x0165);
/* The named colours are one run, which the mirror indexes by offset: its
 * two ends pin it, so a name inserted anywhere moves one of them. */
CHECK("the named colours start with aliceblue at 0x0034",
      LXB_CSS_VALUE_ALICEBLUE == 0x0034);
CHECK("and end with yellowgreen at 0x00c7", LXB_CSS_VALUE_YELLOWGREEN == 0x00c7);
