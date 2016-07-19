#!/usr/bin/env julia

#=
 Licensing Information: You are free to use or extend these projects for 
 education or reserach purposes provided that (1) you retain this notice
 and (2) you provide clear attribution to UC Berkeley, including a link 
 to http://barc-project.com

 Attibution Information: The barc project ROS code-base was developed
 at UC Berkeley in the Model Predictive Control (MPC) lab by Jon Gonzales
 (jon.gonzales@berkeley.edu). The cloud services integation with ROS was developed
 by Kiet Lam  (kiet.lam@berkeley.edu). The web-server app Dator was 
 based on an open source project by Bruce Wootton
=# 

using RobotOS
@rosimport barc.msg: ECU, Encoder, Ultrasound, Z_KinBkMdl
@rosimport data_service.msg: TimeData
@rosimport geometry_msgs.msg: Vector3
rostypegen()
using barc.msg
using data_service.msg
using geometry_msgs.msg
using JuMP
using Ipopt

# define model parameters
L_a     = 0.125         # distance from CoG to front axel
L_b     = 0.125         # distance from CoG to rear axel
dt      = 0.1           # time step of system

# preview horizon
N       = 10

# define targets [generic values]
x_ref   = 1.0
y_ref   = -0.5

# define decision variables 
# states: position (x,y), yaw angle, and velocity
# inputs: acceleration, steering angle 
println("Creating kinematic bicycle model ....")
mdl     = Model(solver = IpoptSolver(print_level=3))
@defVar(mdl, x[1:(N+1)])
@defVar(mdl, y[1:(N+1)])
@defVar(mdl, psi[1:(N+1)])
@defVar(mdl, -2 <= v[1:(N+1)] <= 2)
@defVar(mdl, -30*pi/180.0 <= d_f[1:N] <= 30*pi/180.0)
@defVar(mdl, -1 <= a[1:N] <= 1)

# define objective function
@setNLObjective(mdl, Min, (x[N+1] - x_ref)^2 + (y[N+1] - y_ref)^2 + v[N+1]^2)

# define constraints
# define system dynamics
# Reference: R.Rajamani, Vehicle Dynamics and Control, set. Mechanical Engineering Series,
#               Spring, 2011, page 26
# initial condition
@defNLParam(mdl, x0     == 0); @addNLConstraint(mdl, x[1]     == x0);
@defNLParam(mdl, y0     == 0); @addNLConstraint(mdl, y[1]     == y0);
@defNLParam(mdl, psi0   == 0); @addNLConstraint(mdl, psi[1]   == psi0 );
@defNLParam(mdl, v0     == 0); @addNLConstraint(mdl, v[1]     == v0);

# model dynamics
@defNLExpr(mdl,  bta[i=1:N], atan( L_a / (L_a + L_b) * tan(d_f[i]) ) )
for i in 1:N
    @addNLConstraint(mdl, x[i+1]    == x[i]      + dt*(v[i]*cos( psi[i] + bta[i] ))  )
    @addNLConstraint(mdl, y[i+1]    == y[i]      + dt*(v[i]*sin( psi[i] + bta[i] ))  )
    @addNLConstraint(mdl, psi[i+1]  == psi[i]    + dt*(v[i]/L_b * sin(bta[i]))  )
    @addNLConstraint(mdl, v[i+1]    == v[i]      + dt*(a[i])  )
    #@addNLConstraint(mdl, a[i]  <= 1 )
end

# status update
println("initial solve ...")
solve(mdl)
println("finished initial solve!")

function SE_callback(msg::Z_KinBkMdl)
    # update mpc initial condition 
    setValue(x0,    msg.x)
    setValue(y0,    msg.y)
    setValue(psi0,  msg.psi)
    setValue(v0,    msg.v)
end

function main()
    # initiate node, set up publisher / subscriber topics
    init_node("mpc")
    pub = Publisher("ecu", ECU, queue_size=10)
    s1  = Subscriber("state_estimate", Z_KinBkMdl, SE_callback, queue_size=10)
    
    # set rate
    loop_rate = Rate(10)

    is_parked = 0
    while ! is_shutdown() && is_parked == 0 
        # run mpc, publish command
        solve(mdl)

        # get optimal solutions
        a_opt   = getValue(a[1])
        d_f_opt = getValue(d_f[1])

        # apply ecu command
        cmd     = ECU(a_opt, d_f_opt)
        publish(pub, cmd)

        x_curr = getValue(x0)
        y_curr = getValue(y0)
        psi_curr = getValue(psi0)
        v_curr = getValue(v0)

        if abs(x_curr - x_ref) <= 0.05 && abs(y_curr - y_ref) <= 0.05 && abs(psi_curr) <= 0.05 && abs(v_curr) <= 0.05
            is_parked = 1
        end

        # sleep
        rossleep(loop_rate)
    end
    cmd = ECU(0,0)
    publish(pub,cmd)
    println("parked!")
end

if ! isinteractive()
    main()
end
