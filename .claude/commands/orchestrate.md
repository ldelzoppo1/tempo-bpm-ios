Leggi CLAUDE.md per il contesto completo del progetto, poi avvia il workflow dell'Orchestratore come descritto in `.claude/agents/orchestrator.md`.

Se viene specificata un'epica (es. "TBD-1"), focalizzati su quella.
Se non viene specificata nessuna epica, leggi il backlog Jira (progetto TBD, cloud ID `35eff5dd-e24b-4151-82e5-ae0d4aacc688`) e scegli l'epica con priorità più alta ancora "Da completare", rispettando l'ordine di dipendenze: TBD-1 → TBD-2 → TBD-3/TBD-4 (parallele) → TBD-5 → TBD-6.

Segui il flusso completo:
1. Attiva Planner sull'epica scelta
2. Attendi plan review dal Reviewer
3. Se approvato, assegna i task agli agenti esecutivi
4. Attendi code review dal Reviewer
5. Se approvato, attiva Git Agent
6. Aggiorna Jira
