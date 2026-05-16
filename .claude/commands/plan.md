Leggi CLAUDE.md per il contesto del progetto, poi attiva il Planner/Architect come descritto in `.claude/agents/planner.md`.

Argomento atteso: chiave dell'epica Jira (es. "TBD-1", "TBD-2", ...).

Il Planner deve:
1. Leggere i dettagli dell'epica da Jira (cloud ID `35eff5dd-e24b-4151-82e5-ae0d4aacc688`)
2. Consultare Figma (file key `skEXOLj2h5Ady5OL3JmRIC`) se l'epica è UI-related
3. Creare i subtask tecnici su Jira con AC e specifiche
4. Produrre il piano testuale con ordine di esecuzione

Dopo che il Planner ha finito, passa il piano al Reviewer per la plan review.
