# Not an ADR

A directory holding markdown that is not named `NNNN-title.md`. The checker must
say the directory holds no ADRs rather than reporting a clean run over nothing:
a gate that passes when it found nothing to check is a gate that passes when
someone moves the directory.
