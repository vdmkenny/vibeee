/* Nothing, deliberately.
 *
 * The engine's sound feature was written against SDL and includes this
 * header wherever the feature is on. It uses nothing from it: the two
 * mentions of SDL_mixer left in that file are comments about a version of
 * it that had a bug. This port supplies the sound itself, so the include
 * has to resolve and has nothing to resolve to.
 *
 * A file this empty is still better than switching the feature off, which
 * would leave the engine with no sound at all, and better than editing the
 * engine, which is fetched rather than kept and would lose the edit. */
