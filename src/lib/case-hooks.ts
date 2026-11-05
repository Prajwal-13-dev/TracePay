import 'server-only';
import type { PoolClient } from 'pg';

// Called inside the complaint transaction. Phase 9 stores the narrative embedding here.
export async function afterCaseInsert(_c: PoolClient, _caseId: number, _narrative: string): Promise<void> {}
