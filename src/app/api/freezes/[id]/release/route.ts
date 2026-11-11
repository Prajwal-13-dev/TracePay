// Release an active freeze early (procedure release_freeze): only when nothing is allocated from it.
import { z } from 'zod';
import { route, idParam } from '@/lib/api';
import { withTx } from '@/lib/db';

export const POST = route(['SUPERVISOR'], z.object({}), ({ user, params }) =>
  withTx(user, async c => {
    await c.query('CALL release_freeze($1)', [idParam(params)]);
  }));
