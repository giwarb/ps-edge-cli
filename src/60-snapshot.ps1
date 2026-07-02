function Get-PseSnapshotJs {
    param(
        [AllowNull()]
        [string]$Selector
    )

    $selectorJson = 'null'
    if ($PSBoundParameters.ContainsKey('Selector') -and $null -ne $Selector) {
        $selectorJson = ConvertTo-PseJson $Selector
    }

    $js = @'
(function() {
  var selector = __PSE_SELECTOR__;
  var noMatchPrefix = "\u0000PSE_NO_MATCH\u0000";
  var lines = [];
  var refCounter = 1;
  window.__pseRefs = {};

  function clean(value) {
    if (value === null || value === undefined) {
      return "";
    }
    return String(value).replace(/\s+/g, " ").trim();
  }

  function truncate(value, max) {
    value = clean(value);
    if (value.length > max) {
      return value.slice(0, max - 1) + "\u2026";
    }
    return value;
  }

  function quote(value) {
    return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
  }

  function tagName(el) {
    try {
      return (el.tagName || "").toLowerCase();
    } catch (e) {
      return "";
    }
  }

  function attr(el, name) {
    try {
      return el.getAttribute(name);
    } catch (e) {
      return null;
    }
  }

  function isInvisible(el) {
    try {
      var tag = tagName(el);
      if (tag === "script" || tag === "style" || tag === "noscript" || tag === "template" || tag === "head") {
        return true;
      }
      var style = window.getComputedStyle(el);
      if (style && (style.display === "none" || style.visibility === "hidden")) {
        return true;
      }
      var rect = el.getBoundingClientRect();
      if (rect && rect.width === 0 && rect.height === 0) {
        return true;
      }
    } catch (e) {
      return false;
    }
    return false;
  }

  function associatedLabel(el) {
    try {
      if (el.id) {
        var byFor = document.querySelector('label[for="' + String(el.id).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"]');
        if (byFor) {
          var byForText = clean(byFor.innerText || byFor.textContent);
          if (byForText) {
            return byForText;
          }
        }
      }
    } catch (e) {
    }
    try {
      var parent = el.parentElement;
      while (parent) {
        if (tagName(parent) === "label") {
          var wrappingText = clean(parent.innerText || parent.textContent);
          if (wrappingText) {
            return wrappingText;
          }
          break;
        }
        parent = parent.parentElement;
      }
    } catch (e2) {
    }
    return "";
  }

  function roleOf(el) {
    var tag = tagName(el);
    var explicitRole = clean(attr(el, "role")).toLowerCase();
    var type = clean(attr(el, "type")).toLowerCase();
    if (tag === "a" && attr(el, "href")) { return "link"; }
    if (explicitRole === "button") { return "button"; }
    if (explicitRole === "link") { return "link"; }
    if (tag === "button") { return "button"; }
    if (tag === "input" && (type === "button" || type === "submit" || type === "reset")) { return "button"; }
    if (tag === "input" && (type === "" || type === "text" || type === "email" || type === "password" || type === "search" || type === "tel" || type === "url" || type === "number")) { return "textbox"; }
    if (tag === "textarea") { return "textbox"; }
    if (tag === "input" && type === "checkbox") { return "checkbox"; }
    if (tag === "input" && type === "radio") { return "radio"; }
    if (tag === "select") { return "combobox"; }
    if (tag === "option") { return "option"; }
    if (tag === "img") { return "img"; }
    if (/^h[1-6]$/.test(tag)) { return "heading"; }
    if (tag === "nav") { return "navigation"; }
    if (tag === "main") { return "main"; }
    if (tag === "form") { return "form"; }
    if (tag === "ul" || tag === "ol") { return "list"; }
    if (tag === "li") { return "listitem"; }
    if (tag === "table") { return "table"; }
    if (tag === "tr") { return "row"; }
    if (tag === "td" || tag === "th") { return "cell"; }
    if (tag === "iframe") { return "iframe"; }
    return "";
  }

  function nameOf(el, role) {
    var value = "";
    try { value = clean(attr(el, "aria-label")); } catch (e0) {}
    if (!value) { value = associatedLabel(el); }
    try { if (!value) { value = clean(attr(el, "placeholder")); } } catch (e1) {}
    try { if (!value) { value = clean(attr(el, "alt")); } } catch (e2) {}
    try { if (!value) { value = clean(attr(el, "title")); } } catch (e3) {}
    try {
      if (!value && role === "button" && el.value) {
        value = clean(el.value);
      }
    } catch (e4) {
    }
    try {
      if (!value) {
        value = clean(el.innerText || el.textContent);
      }
    } catch (e5) {
    }
    return truncate(value, 80);
  }

  function isInteractive(el, role) {
    if (role === "link" || role === "button" || role === "textbox" || role === "checkbox" || role === "radio" || role === "combobox" || role === "option") {
      return true;
    }
    try {
      var explicitRole = clean(attr(el, "role")).toLowerCase();
      if (explicitRole === "button" || explicitRole === "link") {
        return true;
      }
      if (typeof el.onclick === "function" || attr(el, "onclick") !== null) {
        return true;
      }
      var tabindex = attr(el, "tabindex");
      if (tabindex !== null && parseInt(tabindex, 10) >= 0) {
        return true;
      }
    } catch (e) {
    }
    return false;
  }

  function isTextContainer(el) {
    var tag = tagName(el);
    return tag === "div" || tag === "p" || tag === "span" || tag === "section" || tag === "article" || tag === "body" || tag === "main" || tag === "li" || tag === "td" || tag === "th" || tag === "label" || tag === "form";
  }

  function lineForElement(el, depth) {
    var role = roleOf(el);
    if (!role) {
      return { emitted: false, role: "", name: "", usedInnerText: false };
    }

    var name = nameOf(el, role);
    var textName = "";
    try { textName = truncate(el.innerText || el.textContent, 80); } catch (e) {}
    var usedInnerText = !!name && name === textName;
    var line = new Array(depth + 1).join("  ") + "- " + role;
    if (name) {
      line += " " + quote(name);
    }
    if (isInteractive(el, role)) {
      var ref = "e" + refCounter++;
      window.__pseRefs[ref] = el;
      line += " [ref=" + ref + "]";
    }
    if (role === "heading") {
      line += " [level=" + tagName(el).substr(1) + "]";
    }
    try { if ((role === "checkbox" || role === "radio") && el.checked) { line += " [checked]"; } } catch (e2) {}
    try { if (el.disabled) { line += " [disabled]"; } } catch (e3) {}
    try { if (role === "option" && el.selected) { line += " [selected]"; } } catch (e4) {}
    lines.push(line);
    return { emitted: true, role: role, name: name, usedInnerText: usedInnerText };
  }

  function walk(node, depth) {
    try {
      if (!node) {
        return;
      }
      if (node.nodeType === 3) {
        var parent = node.parentElement;
        if (parent && isTextContainer(parent) && !parent.__pseUsedInnerTextName) {
          var text = truncate(node.nodeValue, 200);
          if (text) {
            lines.push(new Array(depth + 1).join("  ") + "- text: " + text);
          }
        }
        return;
      }
      if (node.nodeType !== 1) {
        return;
      }
      var el = node;
      if (isInvisible(el)) {
        return;
      }
      var info = lineForElement(el, depth);
      try { el.__pseUsedInnerTextName = info.usedInnerText; } catch (e1) {}
      var childDepth = depth;
      if (info.emitted) {
        childDepth = depth + 1;
      }
      var children = el.childNodes;
      for (var i = 0; i < children.length; i++) {
        walk(children[i], childDepth);
      }
      try { delete el.__pseUsedInnerTextName; } catch (e2) {}
    } catch (e) {
    }
  }

  var root = document.body;
  if (selector !== null && selector !== undefined && selector !== "") {
    try {
      root = document.querySelector(selector);
    } catch (e) {
      root = null;
    }
    if (!root) {
      return noMatchPrefix + selector;
    }
  }

  lines.push("- document " + quote(truncate(document.title || "", 80)));
  walk(root, 1);
  return lines.join("\n");
})()
'@

    return $js.Replace('__PSE_SELECTOR__', $selectorJson)
}
