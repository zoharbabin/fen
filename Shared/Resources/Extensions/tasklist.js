(function () {
  // cmark-gfm's tasklist extension emits <li><input type="checkbox" disabled ...
  // directly, with no wrapping "task-list-item" class, so match the checkbox itself.
  var checkboxes = document.querySelectorAll('li > input[type="checkbox"]');
  for (var i = 0; i < checkboxes.length; i++) {
    checkboxes[i].disabled = true;
  }
})();
