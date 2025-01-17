# Copyright (c) Mathias Kaerlev 2011-2012.

# This file is part of pyspades.

# pyspades is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# pyspades is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with pyspades.  If not, see <http://www.gnu.org/licenses/>.

import math
import time
from pyspades.vxl cimport VXLData, MapData
from pyspades.common cimport Vertex3, create_proxy_vector
from libc.math cimport sqrt, sin, cos, acos, fabs
from pyspades.constants import TORSO, HEAD, ARMS, LEGS, MELEE

cdef extern from "common_c.h":
    struct LongVector:
        int x, y, z
    struct Vector:
        float x, y, z

cdef extern from "world_c.cpp":
    enum:
        CUBE_ARRAY_LENGTH
    int c_validate_hit "validate_hit" (
        float shooter_x, float shooter_y, float shooter_z,
        float orientation_x, float orientation_y, float orientation_z,
        float victim_x, float victim_y, float victim_z, float aim_tolerance, float dist_tolerance)
    int c_can_see "can_see" (MapData * map, float x0, float y0, float z0,
        float x1, float y1, float z1)
    int c_cast_ray "cast_ray" (MapData * map, float x0, float y0, float z0,
        float x1, float y1, float z1, float length, long* x, long* y, long* z)
    size_t cube_line_c "cube_line"(int, int, int, int, int, int, LongVector *)
    void set_globals(MapData * map, float total_time, float dt)
    struct PlayerType:
        Vector p, e, v, s, h, f
        int mf, mb, ml, mr
        int jump, crouch, sneak
        int airborne, wade, alive, sprint
        int primary_fire, secondary_fire, weapon

    struct GrenadeType:
        Vector p, v
    PlayerType * create_player()
    void destroy_player(PlayerType * player)
    void destroy_grenade(GrenadeType * player)
    void update_timer(float value, float dt)
    void reorient_player(PlayerType * p, Vector * vector)
    int move_player(PlayerType * p)
    int try_uncrouch(PlayerType * p)
    GrenadeType * create_grenade(Vector * p, Vector * v)
    int move_grenade(GrenadeType * grenade)

from libc.math cimport sqrt

cdef inline bint can_see(VXLData map, float x1, float y1, float z1,
    float x2, float y2, float z2):
    return c_can_see(map.map, x1, y1, z1, x2, y2, z2)

cdef inline bint cast_ray(VXLData map, float x1, float y1, float z1,
    float x2, float y2, float z2, float length, long* x, long* y, long* z):
    return c_cast_ray(map.map, x1, y1, z1, x2, y2, z2, length, x, y, z)

cdef class Object
cdef class World
cdef class Grenade
cdef class Character

cdef class Object:
    """an object in present in the World"""
    cdef public:
        object name
        World world

    def __init__(self, world, *arg, **kw):
        self.world = world
        self.initialize(*arg, **kw)
        if self.name is None:
            self.name = 'object'

    def initialize(self, *arg, **kw):
        """hook called on Object creation

        Arguments passed to ``__init__`` will be passed here too.
        """
        pass

    cdef int update(self, double dt) except -1:
        '''update this object, giving it a "Tick"'''
        return 0

    def delete(self):
        """remove this object from the World"""
        self.world.delete_object(self)

cdef class Character(Object):
    """Represents the position, orientation and velocity of the player object in
    the world"""
    cdef:
        PlayerType * player
    cdef public:
        Vertex3 position, orientation, velocity
        object fall_callback

    def initialize(self, Vertex3 position, Vertex3 orientation,
                   fall_callback = None):
        self.name = 'character'
        self.player = create_player()
        self.fall_callback = fall_callback
        self.position = create_proxy_vector(&self.player.p)
        self.orientation = create_proxy_vector(&self.player.f)
        self.velocity = create_proxy_vector(&self.player.v)
        if position is not None:
            self.set_position(*position.get())
        if orientation is not None:
            self.orientation.set_vector(orientation)

    def set_crouch(self, bint value):
        """set if the player is crouching"""
        if value == self.player.crouch:
            return
        if value:
            self.player.p.z += 0.9
        else:
            self.player.p.z -= 0.9
        self.player.crouch = value

    def set_animation(self, jump, crouch, sneak, sprint):
        """set all of the player's movement statuses: jump, crouch, sneak and
        sprint"""
        self.player.jump = jump
        self.set_crouch(crouch)
        self.player.sneak = sneak
        self.player.sprint = sprint

    def set_weapon(self, is_primary):
        """set the primary weapon of the player"""
        self.player.weapon = is_primary

    def set_walk(self, up, down, left, right):
        """set the current status of the movement buttons"""
        self.player.mf = up
        self.player.mb = down
        self.player.ml = left
        self.player.mr = right

    def set_position(self, x, y, z, reset = False):
        """set the current position of the player. If ``reset=True`` is passed,
        reset velocity, keys, mouse buttons and movement status as well"""
        self.position.set(x, y, z)
        self.player.p.x = self.player.e.x = x
        self.player.p.y = self.player.e.y = y
        self.player.p.z = self.player.e.z = z
        if reset:
            self.velocity.set(0.0, 0.0, 0.0)
            self.primary_fire = self.secondary_fire = False
            self.jump = self.crouch = False
            self.up = self.down = self.left = self.right = False

    def set_orientation(self, x, y, z):
        """set the current orientation of the Player"""
        cdef Vertex3 v = Vertex3(x, y, z)
        v.normalize()
        reorient_player(self.player, v.value)

    def get_hit_direction(self, Vertex3 position):
        # 0 = aligned
        # 1 = left
        # 2 = right
        # 3 = up
        # 4 = down
        cdef double x, y, z
        x, y, z = position.get()
        x -= self.position.x
        y -= self.position.y
        z -= self.position.z
        cdef Vertex3 orientation = self.orientation
        cdef double cz = (
            orientation.z * z +
            orientation.x * x +
            orientation.y * y
        )

        cdef double r
        if cz == 0.0:
            r = 0
        else:
            r = 1.0 / cz

        cdef double xypow2 = orientation.y ** 2 + orientation.x ** 2

        cdef double orientx_over_vecxy, orienty_over_vecxy

        if xypow2 == 0.0:
            orienty_over_vecxy = orientx_over_vecxy = 0
        else:
            orienty_over_vecxy = -orientation.y / xypow2
            orientx_over_vecxy = orientation.x / xypow2

        cdef double cx = (
            orientx_over_vecxy * y +
            orienty_over_vecxy * x #+
            #always_null * z
        )

        cdef double orientx_over_vecxy2 = orientx_over_vecxy * -orientation.z
        cdef double orientvecxyz = orienty_over_vecxy * orientation.z
        cdef double orient_vecxy_again = (
            orientx_over_vecxy * orientation.x -
            orienty_over_vecxy * orientation.y)

        cdef double x2 = cx * r
        cdef double cy = (
            orientx_over_vecxy2 * x +
            orientvecxyz * y +
            orient_vecxy_again * z
        )
        cdef double y2 = cy * r
        if fabs(x2) < 0.25 and fabs(y2) < 0.25:
            return 0

        if fabs(x2) >= fabs(y2):
            if cz >= 0:
                if x2 < 0:
                    return 1
                else:
                    return 2
            else:
                if x2 < 0:
                    return 2
                else:
                    return 1
        if cz >= 0:
            if y2 < 0:
                return 3
            else:
                return 4
        else:
            if y2 < 0:
                return 4
            else:
                return 3

    cpdef int can_see(self, float x, float y, float z):
        """return if the player can see a given coordinate. This only considers
        the map voxels, not any other objects"""
        cdef Vertex3 position = self.position
        return can_see(self.world.map, position.x, position.y, position.z,
            x, y, z)

    cpdef cast_ray(self, length = 32.0):
        """cast a ray ``length`` number of blocks in the direction the player is
        facing, If a voxel is hit, return it's coordinates, otherwise `None`"""
        cdef Vertex3 position = self.position
        cdef Vertex3 direction = self.orientation.copy().normal()
        cdef long x, y, z
        if cast_ray(self.world.map, position.x, position.y, position.z,
            direction.x, direction.y, direction.z, length, &x, &y, &z):
            return x, y, z
        return None

    def validate_hit(self, Character other, part, float aim_tolerance, float dist_tolerance):
        """check if a given hit is within a given tolerance of hitting another
        player. This is primarily used to prevent players from shooting at
        things they aren't facing at"""
        cdef Vertex3 position1 = self.position
        cdef Vertex3 orientation = self.orientation
        cdef Vertex3 position2 = other.position
        cdef float x, y, z
        x = position2.x
        y = position2.y
        z = position2.z
        if part in (TORSO, ARMS):
            z += 0.9
        elif part == HEAD:
            pass
        elif part == LEGS:
            z += 1.8
        elif part == MELEE:
            z += 0.9
        else:
            return False
        if not c_validate_hit(position1.x, position1.y, position1.z,
                              orientation.x, orientation.y, orientation.z,
                              x, y, z, aim_tolerance, dist_tolerance):
            return False
        return True

    def set_dead(self, value):
        """set the player's alive status. Also resets mouse buttons, movement
        stats and keys"""
        self.player.alive = not value
        self.player.mf = False
        self.player.mb = False
        self.player.ml = False
        self.player.mr = False
        self.player.crouch = False
        self.player.sneak = False
        self.player.primary_fire = False
        self.player.secondary_fire = False
        self.player.sprint = False

    cdef int update(self, double dt) except -1:
        cdef long ret = move_player(self.player)
        if ret > 0:
            self.fall_callback(ret)
        return 0

    # properties
    property up:
        def __get__(self):
            return self.player.mf
        def __set__(self, value):
            self.player.mf = value

    property down:
        def __get__(self):
            return self.player.mb
        def __set__(self, value):
            self.player.mb = value

    property left:
        def __get__(self):
            return self.player.ml
        def __set__(self, value):
            self.player.ml = value

    property right:
        def __get__(self):
            return self.player.mr
        def __set__(self, value):
            self.player.mr = value

    property dead:
        def __get__(self):
            return not self.player.alive
        def __set__(self, bint value):
            self.set_dead(value)

    property jump:
        def __get__(self):
            return self.player.jump
        def __set__(self, value):
            self.player.jump = value

    property airborne:
        def __get__(self):
            return self.player.airborne

    property crouch:
        def __get__(self):
            return self.player.crouch
        def __set__(self, value):
            self.player.crouch = value

    property sneak:
        def __get__(self):
            return self.player.sneak
        def __set__(self, value):
            self.player.sneak = value

    property wade:
        def __get__(self):
            return self.player.wade

    property sprint:
        def __get__(self):
            return self.player.sprint
        def __set__(self, value):
            self.player.sprint = value

    property primary_fire:
        def __get__(self):
            return self.player.primary_fire
        def __set__(self, value):
            self.player.primary_fire = value

    property secondary_fire:
        def __get__(self):
            return self.player.secondary_fire
        def __set__(self, value):
            self.player.secondary_fire = value

    def __repr__(self):
        return f"Character(pos={self.position}, orientation={self.orientation})"

cdef class Grenade(Object):
    cdef public:
        Vertex3 position, velocity
        float fuse
        object callback
        object team
    cdef GrenadeType * grenade

    def initialize(self, double fuse, Vertex3 position, Vertex3 orientation,
                   Vertex3 velocity, callback = None):
        self.name = 'grenade'
        self.grenade = create_grenade(position.value, velocity.value)
        self.position = create_proxy_vector(&self.grenade.p)
        self.velocity = create_proxy_vector(&self.grenade.v)
        if orientation is not None:
            self.velocity += orientation
        self.fuse = fuse
        self.callback = callback

    cdef int hit_test(self, Vertex3 position):
        """check if the grenade can hit something in a given position. This is
        used to check if the player should be damaged"""
        cdef Vector * nade = self.position.value
        return can_see(self.world.map, position.x, position.y, position.z,
                       nade.x, nade.y, nade.z)

    cpdef get_next_collision(self, double dt):
        """calculate the position of the grenade ahead of time.

        Returns:
            eta, x, y, z: the ETA and the location of the next collision
        """
        if self.velocity.is_zero():
            return None
        cdef double eta = 0.0
        cdef double x, y, z
        cdef Vertex3 old_position = self.position.copy()
        cdef Vertex3 old_velocity = self.velocity.copy()
        while move_grenade(self.grenade) == 0:
            eta += dt
            if eta > 5.0:
                break
        x, y, z = self.position.x, self.position.y, self.position.z
        self.position.set_vector(old_position)
        self.velocity.set_vector(old_velocity)
        return eta, x, y, z

    cpdef double get_damage(self, Vertex3 player_position):
        """Calculate the damage given to a player standing at
        ``player_position``. Also performs a check to see if the player is
        behind cover."""
        cdef Vector * position = self.position.value
        cdef double diff_x, diff_y, diff_z
        diff_x = player_position.x - position.x
        diff_y = player_position.y - position.y
        diff_z = player_position.z - position.z
        cdef double value
        if (fabs(diff_x) < 16 and
            fabs(diff_y) < 16 and
            fabs(diff_z) < 16 and
            self.hit_test(player_position)):
            value = diff_x**2 + diff_y**2 + diff_z**2
            if value == 0.0:
                return 100.0
            return 4096.0 / value
        return 0

    cdef int update(self, double dt) except -1:
        self.fuse -= dt
        if self.fuse <= 0:
            if self.callback is not None:
                self.callback(self)
            self.delete()
            return 0
        move_grenade(self.grenade)

    def __dealloc__(self):
        destroy_grenade(self.grenade)

    def __repr__(self):
        rep = "Grenade(fuse={:.3f}, position={}, (...), velocity={})"
        return rep.format(self.fuse, self.position, self.velocity)

cdef class World(object):
    """controls the map of the World and the Objects inside of it"""
    cdef public:
        VXLData map
        list objects
        float time

    def __init__(self):
        self.objects = []
        self.time = 0

    def update(self, double dt):
        if self.map is None:
            return
        self.time += dt
        set_globals(self.map.map, self.time, dt)
        cdef Object instance
        for instance in self.objects[:]:
            instance.update(dt)

    cpdef delete_object(self, Object item):
        self.objects.remove(item)

    def create_object(self, klass, *arg, **kw):
        new_object = klass(self, *arg, **kw)
        self.objects.append(new_object)
        return new_object

# utility functions

cpdef cube_line(x1, y1, z1, x2, y2, z2):
    """create a cube line from one point to another with the same algorithm as
    the client uses"""
    cdef LongVector array[CUBE_ARRAY_LENGTH]
    cdef size_t size = cube_line_c(x1, y1, z1, x2, y2, z2, array)
    cdef size_t i
    cdef list points = []
    for i in range(size):
        points.append((array[i].x, array[i].y, array[i].z))
    return points
