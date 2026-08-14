function Get-PseInspectJs {
    param(
        [AllowNull()]
        [string]$Selector,

        [int]$MaxItems = 200
    )

    $selectorJson = 'null'
    if ($PSBoundParameters.ContainsKey('Selector') -and $null -ne $Selector) {
        $selectorJson = ConvertTo-PseJson $Selector
    }

    $js = @'
(function() {
  var selector = __PSE_SELECTOR__;
  var maxItems = __PSE_MAX_ITEMS__;
  var noMatchPrefix = "\u0000PSE_NO_MATCH\u0000";
  var invalidPrefix = "\u0000PSE_INVALID_SELECTOR\u0000";
  var root = document.body;
  if (selector !== null && selector !== undefined && selector !== "") {
    try {
      root = document.querySelector(selector);
    } catch (e) {
      return invalidPrefix + selector;
    }
    if (!root) {
      return noMatchPrefix + selector;
    }
  }

  function clean(value) {
    return value === null || value === undefined ? "" : String(value).replace(/\s+/g, " ").trim();
  }
  function tagName(el) {
    return clean(el && el.tagName).toLowerCase();
  }
  function attr(el, name) {
    try { return el.getAttribute(name); } catch (e) { return null; }
  }
  function visible(el) {
    try {
      var style = window.getComputedStyle(el);
      if (style.display === "none" || style.visibility === "hidden") { return false; }
      var rect = el.getBoundingClientRect();
      return rect.width !== 0 || rect.height !== 0;
    } catch (e) {
      return false;
    }
  }
  function roleOf(el) {
    var tag = tagName(el);
    var role = clean(attr(el, "role")).toLowerCase();
    var type = clean(attr(el, "type")).toLowerCase();
    if (role) { return role; }
    if (tag === "a" && attr(el, "href")) { return "link"; }
    if (tag === "button" || (tag === "input" && /^(button|submit|reset)$/.test(type))) { return "button"; }
    if (tag === "select") { return "combobox"; }
    if (tag === "textarea" || (tag === "input" && !/^(button|submit|reset|checkbox|radio|file|hidden)$/.test(type))) { return "textbox"; }
    if (tag === "input" && type === "checkbox") { return "checkbox"; }
    if (tag === "input" && type === "radio") { return "radio"; }
    if (tag === "input" && type === "file") { return "button"; }
    return "interactive";
  }
  function labelOf(el) {
    var value = clean(attr(el, "aria-label"));
    if (!value && el.labels && el.labels.length) {
      value = clean(Array.prototype.map.call(el.labels, function(label) {
        return label.innerText || label.textContent;
      }).join(" "));
    }
    if (!value) { value = clean(attr(el, "placeholder")); }
    if (!value) { value = clean(attr(el, "alt")); }
    if (!value) { value = clean(attr(el, "title")); }
    if (!value && roleOf(el) === "button") { value = clean(el.value); }
    if (!value) { value = clean(el.innerText || el.textContent); }
    return value.length > 120 ? value.slice(0, 119) + "\u2026" : value;
  }

  var query = 'a[href],button,input:not([type="hidden"]),textarea,select,[role="button"],[role="link"],[role="textbox"],[role="checkbox"],[role="radio"],[tabindex],*[onclick]';
  var candidates = [];
  try {
    if (root.matches && root.matches(query)) { candidates.push(root); }
    candidates = candidates.concat(Array.prototype.slice.call(root.querySelectorAll(query)));
  } catch (e) {
    return invalidPrefix + (selector || "");
  }

  window.__pseRefs = {};
  var items = [];
  for (var i = 0; i < candidates.length; i++) {
    if (maxItems > 0 && items.length >= maxItems) { break; }
    var el = candidates[i];
    if (!visible(el)) { continue; }
    var ref = "e" + (items.length + 1);
    window.__pseRefs[ref] = el;
    var options = null;
    if (tagName(el) === "select") {
      options = Array.prototype.map.call(el.options, function(option) {
        return {
          value: String(option.value),
          label: clean(option.label || option.text),
          selected: !!option.selected
        };
      });
    }
    items.push({
      ref: ref,
      role: roleOf(el),
      name: labelOf(el),
      tag: tagName(el),
      id: clean(el.id),
      nameAttr: clean(attr(el, "name")),
      type: clean(attr(el, "type")).toLowerCase(),
      value: el.value === undefined || el.value === null ? "" : String(el.value),
      checked: !!el.checked,
      disabled: !!el.disabled,
      options: options
    });
  }
  return JSON.stringify(items);
})()
'@

    return $js.Replace('__PSE_SELECTOR__', $selectorJson).Replace('__PSE_MAX_ITEMS__', [string]$MaxItems)
}

function Get-PseInspection {
    param(
        [Parameter(Mandatory = $true)]
        $Session,

        [AllowNull()]
        [string]$Selector,

        [int]$MaxItems = 200
    )

    if ($MaxItems -lt 0) {
        throw '-MaxItems must be 0 or a positive integer'
    }

    $js = Get-PseInspectJs -Selector $Selector -MaxItems $MaxItems
    $json = [string](Invoke-PseInPage -Session $Session -JsExpression $js)
    $noMatchPrefix = [string]([char]0) + 'PSE_NO_MATCH' + [string]([char]0)
    $invalidPrefix = [string]([char]0) + 'PSE_INVALID_SELECTOR' + [string]([char]0)
    if ($json.StartsWith($invalidPrefix)) {
        throw "invalid selector '$Selector'"
    }
    if ($json.StartsWith($noMatchPrefix)) {
        throw "no element matches selector '$Selector'"
    }
    if ([string]::IsNullOrWhiteSpace($json)) {
        return @()
    }
    return @($json | ConvertFrom-Json | ForEach-Object { $_ })
}
