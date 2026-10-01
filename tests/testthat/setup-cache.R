# Tests never touch the user's real cache: the default cache_dir() is a
# folder in the session's temporary directory, removed when R exits. The
# cleanup that runs when the first notebook opens only ever sees it.
options(ember.cache_dir = tempfile("ember-test-cache-"))
